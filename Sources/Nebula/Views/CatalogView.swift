import SwiftUI
import NebulaCore

/// Paged loading of one catalog — shared by "See all" and by Discover.
@MainActor
final class CatalogPager: ObservableObject {
    @Published var items: [MetaItem] = []
    @Published var loading = false
    @Published var failed = false
    private var done = false
    private var seq = 0
    private var fetched = 0
    private var seen = Set<String>()
    private(set) var key = ""

    func reset(addon: Addon, catalog: CatalogRef, genre: String?, stremio: Stremio) async {
        seq += 1
        // a page still out for the old pick will never clear this (it belongs to an old seq),
        // and `more` refuses to start while it is set — without this the grid spun forever
        loading = false
        key = addon.manifestUrl + "|" + catalog.type + "|" + catalog.id + "|" + (genre ?? "")
        items = []; seen = []; fetched = 0; done = false; failed = false
        await more(addon: addon, catalog: catalog, genre: genre, stremio: stremio)
    }

    func more(addon: Addon, catalog: CatalogRef, genre: String?, stremio: Stremio) async {
        guard !loading, !done, items.count < 1000 else { return }
        let mine = seq
        loading = true
        defer { if mine == seq { loading = false } }
        guard let page = try? await stremio.loadCatalog(base: addon.base, catalog: catalog, genre: genre, skip: fetched) else {
            // a request cancelled because the page asked again (Try again, another pick) did not
            // fail: saying "did not answer" for it flashed the error before the new answer
            if mine == seq && !Task.isCancelled { failed = items.isEmpty; done = true }
            return
        }
        guard mine == seq else { return }
        fetched += page.count
        let new = page.filter { seen.insert($0.id).inserted }
        items.append(contentsOf: new)
        // an add-on without paging answers the same page again: nothing new means the end
        if page.isEmpty || new.isEmpty || !catalog.skip { done = true }
    }
}

struct CatalogView: View {
    @EnvironmentObject var model: AppModel
    let target: CatalogTarget
    @StateObject private var pager = CatalogPager()
    @State private var genre: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("\(target.addon.name) · \(typeLabel(target.catalog.type))")
                    Text(target.catalog.name).scaledFont(size: 30, weight: .bold).foregroundStyle(Theme.ink)
                }
                .padding(.top, Theme.pushedTitleTop)
                if !target.catalog.genres.isEmpty {
                    EdgeScroller {
                        Chip(text: "All", on: genre == nil) { genre = nil }
                        ForEach(target.catalog.genres, id: \.self) { g in Chip(text: g, on: genre == g) { genre = g } }
                    }
                }
                PosterGrid(items: pager.items, addonUrl: { _ in target.addon.manifestUrl }) {
                    Task { await pager.more(addon: target.addon, catalog: target.catalog, genre: genre, stremio: model.stremio) }
                }
                if pager.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding() }
                if pager.failed {
                    EmptyState(icon: "wifi.slash", title: "This catalog did not answer", detail: "Check the connection, or try again in a moment.",
                               actionTitle: "Try again", action: { Task { await pager.reset(addon: target.addon, catalog: target.catalog, genre: genre, stremio: model.stremio) } })
                }
                else if !pager.loading && pager.items.isEmpty { EmptyState(icon: "square.grid.2x2", title: "Nothing here.", detail: "This catalog is empty right now.") }
            }
            .padding(.horizontal, Theme.pad).padding(.bottom, 50)
        }
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 22).padding(.top, Theme.backTop) }
        .task(id: genre) { await pager.reset(addon: target.addon, catalog: target.catalog, genre: genre, stremio: model.stremio) }
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var type: String?

    var body: some View {
        let all = model.library.list()
        let types = Array(Set(all.map(\.type))).sorted()
        let shown = all.filter { type == nil || $0.type == type }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("My List").scaledFont(size: 30, weight: .bold).foregroundStyle(Theme.ink)
                    Text("\(all.count)").scaledFont(size: 13, design: .monospaced).foregroundStyle(Theme.label3)
                }
                .padding(.top, 56)
                if types.count > 1 {
                    HStack(spacing: 8) {
                        Chip(text: "All", on: type == nil) { type = nil }
                        ForEach(types, id: \.self) { t in Chip(text: typeLabel(t), on: type == t) { type = t } }
                    }
                }
                if all.isEmpty {
                    EmptyState(icon: "bookmark", title: "Nothing saved yet", detail: "Use the + on any title to keep it here. With a profile, the list follows you to your TV and phone.")
                } else {
                    let urls = Dictionary(all.map { ($0.type + ":" + $0.id, $0.addonUrl) }, uniquingKeysWith: { a, _ in a })
                    PosterGrid(items: shown.map(\.meta), addonUrl: { urls[$0.type + ":" + $0.id] ?? "" })
                }
            }
            .padding(.horizontal, Theme.pad).padding(.bottom, 50)
        }
        .background(Theme.bg)
        .id(model.libraryVersion)
    }
}
