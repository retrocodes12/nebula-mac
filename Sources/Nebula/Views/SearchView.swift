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
                        .textFieldStyle(.plain).scaledFont(size: 16).foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit { run(query) }
                    if !query.isEmpty {
                        Button(action: { query = ""; submitted = ""; results = [] }) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.label3) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 46)
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
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Searching your add-ons…").scaledFont(size: 13).foregroundStyle(Theme.label2) }.padding(.horizontal, Theme.pad)
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
        let list = model.activeAddons
        let m = model, stremio = model.stremio
        Task {
            // each add-on on its own track: its search catalogs are asked the moment its manifest
            // is in, so one add-on asleep on a free host no longer holds up every search
            var catalogs = [[CatalogRef]](repeating: [], count: list.count)
            var rows = [[CatalogRow?]](repeating: [], count: list.count)
            var misses = 0, failures = 0, answered = 0
            await withTaskGroup(of: AddonStep.self) { group in
                for (i, a) in list.enumerated() { group.addTask { .manifest(i, await m.manifest(for: a)) } }
                while let step = await group.next() {
                    guard mine == seq else { group.cancelAll(); return }
                    switch step {
                    case .settled:
                        continue                              // Home's; a search paints as it goes
                    case .manifest(let i, let info):
                        guard let info = info else { misses += 1; continue }
                        let want = info.catalogs.filter(\.search)
                        catalogs[i] = want
                        rows[i] = Array(repeating: nil, count: want.count)
                        let base = list[i].base
                        for (j, c) in want.enumerated() {
                            group.addTask { .catalog(i, j, try? await stremio.loadCatalog(base: base, catalog: c, query: q)) }
                        }
                    case .catalog(let i, let j, let items):
                        guard let items = items else { failures += 1; continue }
                        answered += 1
                        if !items.isEmpty { rows[i][j] = CatalogRow(addon: list[i], catalog: catalogs[i][j], items: Array(items.prefix(40))) }
                        results = rows.joined().compactMap { $0 }
                    }
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
    /// No catalog to offer because add-ons did not answer — not because none has one.
    @State private var unreachable = false

    /// What Discover is built from: the add-ons, and Try again.
    private struct Source: Equatable { var addons: [Addon]; var epoch: Int }

    private var types: [String] {
        var seen = Set<String>()
        return options.map(\.catalog.type).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("Discover")
            if let cur = current {
                // scrolls sideways like every other chip row: three pills that do not shrink are
                // ~440 points, and laid out bare they made the whole page that wide on a phone.
                // Out to the page's edges, so a pill that does not fit fades there instead of
                // being cut at the margin ("GENRE All g")
                EdgeScroller(spacing: 10) {
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
                Text("\(cur.addon.name) • \(typeLabel(cur.catalog.type))").scaledFont(size: 12).foregroundStyle(Theme.label3)
                PosterGrid(items: pager.items, addonUrl: { _ in cur.addon.manifestUrl }) {
                    Task { await pager.more(addon: cur.addon, catalog: cur.catalog, genre: genre, stremio: model.stremio) }
                }
                if pager.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding() }
                else if pager.failed {
                    EmptyState(icon: "wifi.slash", title: "This catalog did not answer", detail: "Check the connection, or try again in a moment.",
                               actionTitle: "Try again", action: { Task { await pager.reset(addon: cur.addon, catalog: cur.catalog, genre: genre, stremio: model.stremio) } })
                }
                else if pager.items.isEmpty { EmptyState(icon: "square.grid.2x2", title: "Nothing here.", detail: "Pick another catalog or genre.") }
            } else if ready && unreachable {
                // an offline launch: say so, and offer the way back — it used to read "Nothing to
                // browse yet" for the rest of the session
                EmptyState(icon: "wifi.slash", title: "Your add-ons could not be reached", detail: "Discover needs them to answer. Check the connection and try again.",
                           actionTitle: "Try again", action: { model.retryHome() })
            } else if ready {
                EmptyState(icon: "square.grid.2x2", title: "Nothing to browse yet", detail: "Add an add-on with a catalog and it shows up here.")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: Source(addons: model.addons, epoch: model.catalogEpoch)) { await load() }
    }

    private func key(_ t: CatalogTarget) -> String { t.addon.manifestUrl + "|" + t.catalog.type + "|" + t.catalog.id }

    private func targets(_ list: [Addon], _ infos: [ManifestInfo?]) -> [CatalogTarget] {
        var out: [CatalogTarget] = []
        for (a, m) in zip(list, infos) {
            for c in m?.catalogs ?? [] where c.browsable { out.append(CatalogTarget(addon: a, catalog: c)) }
        }
        return out
    }

    /// The catalogs of whichever add-ons answer within a few seconds; the ones still waking
    /// join the list when they land. Keyed on the add-ons and on Try again, and a load that a
    /// newer one replaced writes nothing.
    private func load() async {
        let list = model.activeAddons
        var infos = await model.manifests(for: list, within: 4)
        guard !Task.isCancelled else { return }
        if infos.contains(where: { $0 == nil }) {
            let early = targets(list, infos)
            if !early.isEmpty { await show(early, unreachable: false) }
            guard !Task.isCancelled else { return }
            // the late ones get the rest of their time (a recent miss answers nil at once)
            infos = await model.manifests(for: list, within: 25)
            guard !Task.isCancelled else { return }
        }
        let opts = targets(list, infos)
        await show(opts, unreachable: opts.isEmpty && infos.contains { $0 == nil })
    }

    private func show(_ opts: [CatalogTarget], unreachable missed: Bool) async {
        let changed = opts.map(key) != options.map(key)
        options = opts
        unreachable = missed
        ready = true
        // the pick in hand stays when it is still on offer; a grid that failed asks again
        if let cur = current, let same = opts.first(where: { key($0) == key(cur) }) {
            if pager.failed || (!changed && pager.items.isEmpty && !pager.loading) {
                await pager.reset(addon: same.addon, catalog: same.catalog, genre: genre, stremio: model.stremio)
            }
            return
        }
        // else the last pick comes back; else the first catalog there is
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
                Text(label.uppercased()).scaledFont(size: 10, weight: .medium, design: .monospaced).tracking(1).foregroundStyle(Theme.label3)
                Text(value).scaledFont(size: 13, weight: .semibold).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: 220)
                Image(systemName: "chevron.down").scaledFont(size: 9, weight: .bold).foregroundStyle(Theme.label3)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 34)
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
                Text(text).scaledFont(size: 13, weight: on ? .semibold : .regular).lineLimit(1)
                Spacer()
                if on { Image(systemName: "checkmark").scaledFont(size: 11, weight: .bold) }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
