import SwiftUI
import NebulaCore

/// One search across every add-on; while the field is empty, Discover: pick a type, a catalog
/// and a genre and page through it.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var submitted = ""
    @State private var results: [CatalogRow] = []
    @State private var searching = false
    @State private var failedAll = false
    /// Add-ons (or their search catalogs) that did not answer this search.
    @State private var unreachable = 0
    @State private var seq = 0
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.label2)
                    TextField("Films, series, channels", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 16)).foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit { run(query) }
                    if !query.isEmpty {
                        Button(action: { query = ""; submitted = ""; results = [] }) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.label3) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Color.white.opacity(0.5) : Theme.line))
                .frame(maxWidth: Theme.cap(640))
                .padding(.horizontal, Theme.pad).padding(.top, 56)

                if submitted.isEmpty {
                    let recents = model.prefs.recentSearches
                    if !recents.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recents, id: \.self) { q in Chip(text: q) { query = q; run(q) } }
                            }
                            .padding(.horizontal, Theme.pad)
                        }
                    }
                    DiscoverSection().padding(.horizontal, Theme.pad)
                } else {
                    if searching && results.isEmpty {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Searching your add-ons…").font(.system(size: 13)).foregroundStyle(Theme.label2) }.padding(.horizontal, Theme.pad)
                    }
                    ForEach(results) { CatalogRowResults(row: $0) }
                    if !searching && results.isEmpty {
                        if failedAll {
                            EmptyState(icon: "wifi.slash", title: "The search did not go through", detail: "None of your add-ons answered. Check the connection and try again.",
                                       actionTitle: "Try again", action: { model.forgetMisses(); run(submitted) })
                        } else {
                            EmptyState(icon: "magnifyingglass", title: "Nothing for “\(submitted)”",
                                       detail: unreachable > 0 ? "\(unreachable) of your add-ons did not answer. Check the spelling, or try again in a moment."
                                                               : "Check the spelling, or try the original title.")
                        }
                    }
                }
                Color.clear.frame(height: 30)
            }
        }
        .background(Theme.bg)
    }

    private func run(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        submitted = q
        model.prefs.recentSearches = [q] + model.prefs.recentSearches.filter { $0.lowercased() != q.lowercased() }
        seq += 1
        let mine = seq
        results = []; searching = true; failedAll = false; unreachable = 0
        Task {
            let list = model.activeAddons
            let infos = await model.manifests(for: list)
            var targets: [(Addon, CatalogRef)] = []
            for (a, m) in zip(list, infos) {
                for c in m?.catalogs ?? [] where c.search { targets.append((a, c)) }
            }
            let misses = infos.filter { $0 == nil }.count
            var rows = [CatalogRow?](repeating: nil, count: targets.count)
            var failures = 0, answered = 0
            let stremio = model.stremio
            await withTaskGroup(of: (Int, [MetaItem]?).self) { group in
                for (i, t) in targets.enumerated() { group.addTask { (i, try? await stremio.loadCatalog(base: t.0.base, catalog: t.1, query: q)) } }
                for await (i, items) in group {
                    guard mine == seq else { return }
                    guard let items = items else { failures += 1; continue }
                    answered += 1
                    if !items.isEmpty { rows[i] = CatalogRow(addon: targets[i].0, catalog: targets[i].1, items: Array(items.prefix(40))) }
                    results = rows.compactMap { $0 }
                }
            }
            guard mine == seq else { return }
            searching = false
            unreachable = misses + failures
            failedAll = answered == 0 && unreachable > 0
        }
    }
}

/// A search result row: the same cards, headed by where they came from.
struct CatalogRowResults: View {
    let row: CatalogRow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RowHeader(title: typeLabel(row.catalog.type), subline: "from \(row.addon.name) · \(row.items.count)")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(row.items) { PosterCard(item: $0, addonUrl: row.addon.manifestUrl) }
                }
                .padding(.horizontal, Theme.pad).padding(.vertical, 6)
            }
        }
    }
}

struct DiscoverSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var pager = CatalogPager()
    @State private var options: [CatalogTarget] = []
    @State private var current: CatalogTarget?
    @State private var genre: String?
    @State private var ready = false

    private var types: [String] {
        var seen = Set<String>()
        return options.map(\.catalog.type).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("Discover")
            if let cur = current {
                HStack(spacing: 10) {
                    PickMenu(label: "Type", value: typeLabel(cur.catalog.type), options: types.map { ($0, typeLabel($0)) }, current: cur.catalog.type) { t in
                        if let first = options.first(where: { $0.catalog.type == t }) { pick(first, genre: nil) }
                    }
                    PickMenu(label: "Catalog", value: cur.catalog.name,
                             options: options.filter { $0.catalog.type == cur.catalog.type }.map { (key($0), "\($0.catalog.name) — \($0.addon.name)") }, current: key(cur)) { k in
                        if let t = options.first(where: { key($0) == k }) { pick(t, genre: nil) }
                    }
                    if !cur.catalog.genres.isEmpty {
                        PickMenu(label: "Genre", value: genre ?? "All genres", options: [("", "All genres")] + cur.catalog.genres.map { ($0, $0) }, current: genre ?? "") { g in
                            pick(cur, genre: g.isEmpty ? nil : g)
                        }
                    }
                }
                Text("\(cur.addon.name) • \(typeLabel(cur.catalog.type))").font(.system(size: 12)).foregroundStyle(Theme.label3)
                PosterGrid(items: pager.items, addonUrl: { _ in cur.addon.manifestUrl }) {
                    Task { await pager.more(addon: cur.addon, catalog: cur.catalog, genre: genre, stremio: model.stremio) }
                }
                if pager.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding() }
                else if pager.items.isEmpty { EmptyState(icon: "square.grid.2x2", title: "Nothing here.", detail: "Pick another catalog or genre.") }
            } else if ready {
                EmptyState(icon: "square.grid.2x2", title: "Nothing to browse yet", detail: "Add an add-on with a catalog and it shows up here.")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: model.addons) { await load() }
    }

    private func key(_ t: CatalogTarget) -> String { t.addon.manifestUrl + "|" + t.catalog.type + "|" + t.catalog.id }

    private func load() async {
        var opts: [CatalogTarget] = []
        let list = model.activeAddons
        for (a, m) in zip(list, await model.manifests(for: list)) {
            for c in m?.catalogs ?? [] where c.browsable { opts.append(CatalogTarget(addon: a, catalog: c)) }
        }
        options = opts
        ready = true
        // the last pick comes back; else the first catalog there is
        let saved = model.prefs.discover
        let restored = opts.first { key($0) == saved.str("key") }
        if let t = restored ?? opts.first {
            let g = restored != nil ? saved.text("genre") : nil
            current = t; genre = g
            await pager.reset(addon: t.addon, catalog: t.catalog, genre: g, stremio: model.stremio)
        } else { current = nil }
    }

    private func pick(_ t: CatalogTarget, genre g: String?) {
        current = t; genre = g
        model.prefs.discover = ["key": key(t), "genre": g ?? ""]
        Task { await pager.reset(addon: t.addon, catalog: t.catalog, genre: g, stremio: model.stremio) }
    }
}

/// A pill that opens a list: the label small, the value beside it. SwiftUI's own Menu redraws
/// its label in the system's style on a Mac, so this is a button and a popover instead.
struct PickMenu: View {
    let label: String
    let value: String
    let options: [(String, String)]
    let current: String
    let onPick: (String) -> Void
    @State private var open = false

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 8) {
                Text(label.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(Theme.label3)
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: 220)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.label3)
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(open ? Theme.surface2 : Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.line))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options, id: \.0) { o in
                        PickRow(text: o.1, on: o.0 == current) { open = false; onPick(o.0) }
                    }
                }
                .padding(6)
            }
            .frame(width: 280)
            .frame(maxHeight: 360)
            .preferredColorScheme(.dark)
        }
    }
}

struct PickRow: View {
    let text: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
