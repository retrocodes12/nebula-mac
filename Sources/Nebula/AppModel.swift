import SwiftUI
import NebulaCore

enum Tab: String, CaseIterable, Identifiable {
    case home, search, library, addons, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .home: return "Home"; case .search: return "Search"; case .library: return "My List"; case .addons: return "Add-ons"; case .settings: return "Settings" }
    }
    var icon: String {
        switch self { case .home: return "house"; case .search: return "magnifyingglass"; case .library: return "bookmark"; case .addons: return "puzzlepiece.extension"; case .settings: return "gearshape" }
    }
}

struct CatalogTarget: Hashable {
    var addon: Addon
    var catalog: CatalogRef
}

struct StreamsTarget: Hashable {
    var type: String
    /// What streams are asked for: the film's id, or the episode's.
    var id: String
    /// The title the page belongs to (the series, for an episode).
    var item: MetaItem
    var addonUrl: String
    var episode: Episode?
    var videos: [Episode] = []
}

enum Route: Hashable {
    case detail(MetaItem, addonUrl: String)
    case streams(StreamsTarget)
    case catalog(CatalogTarget)
}

struct CatalogRow: Identifiable, Equatable {
    var addon: Addon
    var catalog: CatalogRef
    var items: [MetaItem]
    var id: String { addon.manifestUrl + "|" + catalog.type + "|" + catalog.id }
}

struct StreamSection: Identifiable, Equatable {
    var addon: Addon
    var streams: [StreamItem]
    var id: String { addon.manifestUrl }
}

/// Everything the player needs to play one thing and to know what comes after it.
struct PlayRequest: Identifiable, Equatable {
    let id = UUID()
    var stream: StreamItem
    var target: StreamsTarget
    var streamAddon: Addon?
    var startAt: Double = 0

    var title: String { target.item.name }
    var kicker: String? {
        guard let e = target.episode else { return nil }
        let k = Ids.episodeKicker(e.id) ?? "Episode"
        return e.name.isEmpty || e.name.hasPrefix("Episode") ? k : "\(k) · \(e.name)"
    }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var isError = false
}

@MainActor
final class AppModel: ObservableObject {
    let store: Store
    let addonStore: AddonStore
    let progress: ProgressStore
    let library: LibraryStore
    let prefs: Prefs
    let stremio: Stremio
    let cloud: Cloud

    @Published var tab: Tab = .home
    @Published var path: [Route] = []
    @Published var player: PlayRequest?
    @Published var toast: Toast?
    @Published var addons: [Addon] = []
    @Published var profile: Profile?
    @Published var accentHex: String
    /// Bumped when the progress store or My List changes, so pages that paint ticks, resume
    /// labels or the saved mark re-read them.
    @Published var progressVersion = 0
    @Published var libraryVersion = 0

    @Published var homeRows: [CatalogRow] = []
    @Published var homeLoading = false
    @Published var homeFailed = false
    private var homeSig: String?
    private var homeSeq = 0

    private var manifests: [String: ManifestInfo] = [:]
    private var toastTask: Task<Void, Never>?

    var accent: Color { Color(hex: accentHex) }

    init(store: Store = .standard(), live: Bool = true) {
        self.store = store
        addonStore = AddonStore(store: store)
        progress = ProgressStore(store: store)
        library = LibraryStore(store: store)
        prefs = Prefs(store: store)
        stremio = Stremio()
        cloud = Cloud(store: store, addons: addonStore, progress: progress, library: library,
                      deviceName: Host.current().localizedName ?? "Mac")
        accentHex = prefs.accent
        addonStore.seedIfNeeded()
        addons = addonStore.all()
        profile = cloud.storedProfile()

        let addonsRef = self.addonStore, cloud = self.cloud
        progress.disabledAddons = { Set(addonsRef.all().filter { !$0.enabled }.map(\.manifestUrl)) }
        progress.onChange = { [weak self] in
            Task { await cloud.noteChanged("progress") }
            Task { @MainActor in self?.progressVersion += 1 }
        }
        library.onChange = { [weak self] in
            Task { await cloud.noteChanged("library") }
            Task { @MainActor in self?.libraryVersion += 1 }
        }
        addonsRef.onChange = { Task { await cloud.noteChanged("addons") } }
        guard live else { return }
        Task {
            await cloud.setHandlers(
                onApplied: { [weak self] keys in Task { @MainActor in self?.syncApplied(keys) } },
                onSignedOut: { [weak self] in Task { @MainActor in self?.say("This Mac was signed out of your profile. Nothing on it was deleted.") } },
                onProfile: { [weak self] p in Task { @MainActor in self?.profile = p } })
            await cloud.pullAll(force: true)
            _ = await cloud.refreshProfile()
        }
    }

    // MARK: toasts

    func say(_ text: String, error: Bool = false) {
        toast = Toast(text: text, isError: error)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: error ? 5_000_000_000 : 2_600_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: navigation

    func open(_ item: MetaItem, addonUrl: String) {
        path.append(.detail(item, addonUrl: addonUrl))
    }

    func select(_ t: Tab) {
        if tab == t { path.removeAll() } else { tab = t; path.removeAll() }
    }

    // MARK: add-ons

    func manifest(for addon: Addon) async -> ManifestInfo? {
        if let m = manifests[addon.manifestUrl] { return m }
        guard let m = try? await stremio.loadManifest(addon.manifestUrl) else { return nil }
        manifests[addon.manifestUrl] = m
        return m
    }

    var activeAddons: [Addon] { addons.filter(\.enabled) }

    func saveAddons(_ next: [Addon], reordered: Bool = false) {
        addonStore.save(next, reordered: reordered)
        addons = next
        invalidateHome()
    }

    /// Install from whatever was pasted. Returns nil on success or a sentence to show.
    func installAddon(_ raw: String) async -> String? {
        guard let url = Stremio.addonUrlOf(raw) else { return "Paste the add-on’s address." }
        if addons.contains(where: { $0.manifestUrl == url }) { return "That add-on is already installed." }
        guard let m = try? await stremio.loadManifest(url) else { return "That address did not answer with an add-on." }
        manifests[url] = m
        saveAddons(addons + [m.addon])
        say("Added \(m.addon.name).")
        return nil
    }

    private func syncApplied(_ keys: Set<String>) {
        if keys.contains("addons") { addons = addonStore.all(); manifests.removeAll(); invalidateHome() }
        if keys.contains("progress") { progressVersion += 1 }
        if keys.contains("library") { libraryVersion += 1 }
    }

    // MARK: Home

    func invalidateHome() { homeSig = nil; Task { await loadHome() } }

    func loadHome() async {
        let active = activeAddons
        let sig = active.map(\.manifestUrl).joined(separator: "\n")
        if sig == homeSig && !homeRows.isEmpty { return }
        homeSig = sig
        homeSeq += 1
        let seq = homeSeq
        homeLoading = true; homeFailed = false
        var wanted: [(Addon, CatalogRef)] = []
        for a in active {
            guard let m = await manifest(for: a) else { continue }
            for c in m.catalogs where c.browsable { wanted.append((a, c)) }
        }
        guard seq == homeSeq else { return }
        let targets = Array(wanted.prefix(24))
        var rows = [CatalogRow?](repeating: nil, count: targets.count)
        let stremio = stremio
        await withTaskGroup(of: (Int, [MetaItem]).self) { group in
            for (i, t) in targets.enumerated() {
                group.addTask { (i, (try? await stremio.loadCatalog(base: t.0.base, catalog: t.1)) ?? []) }
            }
            for await (i, items) in group {
                guard seq == homeSeq else { return }
                if !items.isEmpty { rows[i] = CatalogRow(addon: targets[i].0, catalog: targets[i].1, items: Array(items.prefix(30))) }
                homeRows = rows.compactMap { $0 }       // rows paint as they arrive, in the add-ons' order
            }
        }
        guard seq == homeSeq else { return }
        homeLoading = false
        homeFailed = homeRows.isEmpty && !targets.isEmpty
        if homeFailed { homeSig = nil }
    }

    // MARK: meta

    /// The title's own add-on first, then every add-on that says it has meta for the id.
    func loadMeta(_ item: MetaItem, addonUrl: String) async -> (FullMeta, Addon)? {
        let active = activeAddons
        let origin = active.first { $0.manifestUrl == addonUrl }
        let order = (origin.map { [$0] } ?? []) + active.filter { $0.manifestUrl != addonUrl }
        for a in order {
            if a.manifestUrl != addonUrl {
                guard let m = await manifest(for: a), m.canMeta(item.type, item.id) else { continue }
            }
            if let meta = try? await stremio.loadFullMeta(base: a.base, type: item.type, id: item.id), !meta.name.isEmpty || !meta.videos.isEmpty {
                return (meta, a)
            }
        }
        return nil
    }

    // MARK: streams

    func loadStreams(_ t: StreamsTarget, onSection: @escaping (StreamSection) -> Void) async -> Int {
        var askers: [Addon] = []
        for a in activeAddons {
            guard let m = await manifest(for: a), m.stream.has else { continue }
            if a.manifestUrl == t.addonUrl || m.canStream(t.type, t.id) { askers.append(a) }
        }
        let stremio = stremio
        var failures = 0
        await withTaskGroup(of: (Addon, [StreamItem]?).self) { group in
            for a in askers { group.addTask { (a, try? await stremio.loadStreams(base: a.base, type: t.type, id: t.id)) } }
            for await (a, streams) in group {
                guard let s = streams else { failures += 1; continue }
                if !s.isEmpty { onSection(StreamSection(addon: a, streams: s)) }
            }
        }
        return askers.count
    }

    func addonSubtitles(type: String, id: String) async -> [SubTrack] {
        var out: [SubTrack] = []
        for a in activeAddons {
            guard let m = await manifest(for: a), m.canSubs(type, id) else { continue }
            if let subs = try? await stremio.loadSubtitles(base: a.base, type: type, id: id) { out.append(contentsOf: subs) }
        }
        return out
    }

    // MARK: play

    func play(_ stream: StreamItem, target: StreamsTarget, from addon: Addon?, fresh: Bool = false) {
        var req = PlayRequest(stream: stream, target: target, streamAddon: addon)
        if prefs.resume && !fresh { req.startAt = progress.resumeAt(target.type, target.id) }
        player = req
    }

    /// The episode after this one, in the order the series gives them (specials last).
    func nextEpisode(after t: StreamsTarget) -> Episode? {
        guard let cur = t.episode else { return nil }
        let flat = t.videos.filter { $0.season != 0 }.sorted { ($0.season, $0.episode ?? 0) < ($1.season, $1.episode ?? 0) }
        guard let i = flat.firstIndex(where: { $0.id == cur.id }), i + 1 < flat.count else { return nil }
        return flat[i + 1]
    }
}
