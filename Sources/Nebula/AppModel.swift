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

/// One step of asking every add-on at once, each on its own track: its manifest came in (nil:
/// it did not answer), or one of its catalogs did (nil: that request failed).
enum AddonStep: Sendable {
    case manifest(Int, ManifestInfo?)
    case catalog(Int, Int, [MetaItem]?)
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

    /// A newer release than this build, when there is one ("v0.2.0").
    @Published var updateTag: String?

    @Published var homeRows: [CatalogRow] = []
    /// True from the first frame: Home is asked for as soon as the window is up, and before that
    /// the page said "None of the add-ons switched on has a catalog" for a moment.
    @Published var homeLoading = true
    @Published var homeFailed = false
    /// Bumped by Try again, so every page built from the add-ons' catalogs (Discover) asks again.
    @Published var catalogEpoch = 0
    /// The player that is playing right now — loaded, not paused, not at the end, not failed.
    /// Set and cleared by that player only, so a player fading out cannot clear its successor's.
    @Published var playingId: UUID?
    private var homeSig: String?
    private var homeSeq = 0

    private var manifestCache: [String: ManifestInfo] = [:]
    /// Manifests being fetched. A page waits for one only as long as it can afford; the fetch
    /// runs on and lands in the cache (or the misses) for whoever asks next.
    private var manifestLoads: [String: Task<ManifestInfo?, Never>] = [:]
    /// Add-ons whose manifest did not answer: when, and how many times running. Every page
    /// passes them by for a while instead of each waiting out the same timeout again — two
    /// minutes, doubling with each miss in a row up to sixteen. Try again forgets them.
    private var manifestMisses: [String: (at: Date, count: Int)] = [:]
    private static let missFor: TimeInterval = 120, missForAtMost: TimeInterval = 960
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
                      deviceName: Platform.deviceName, platform: Platform.client)
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
                onSignedOut: { [weak self] in Task { @MainActor in self?.say("This \(Platform.deviceWord) was signed out of your profile. Nothing on it was deleted.") } },
                onProfile: { [weak self] p in Task { @MainActor in self?.profile = p } })
            await cloud.pullAll(force: true)
            _ = await cloud.refreshProfile()
        }
        // a pull at launch only meant a Mac left open all day never saw the TV's progress; the
        // Mac also pulls on coming to the front and the phone on becoming active (both throttled
        // to one pull per 45 s inside Cloud, like the web player)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await cloud.pullAll()
            }
        }
        Task { await checkForUpdate() }
    }

    /// One question to the releases page per launch. The app never downloads anything itself:
    /// it says a newer one exists and opens the page.
    func checkForUpdate() async {
        guard let j = try? await stremio.getJSON("https://api.github.com/repos/retrocodes12/nebula-mac/releases/latest"),
              let tag = j.text("tag_name") else { return }
        if AppModel.isNewer(tag, than: AppInfo.version) { updateTag = tag }
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
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
        push(.detail(item, addonUrl: addonUrl))
    }

    /// Every page goes on through here. A double tap or click used to push the same page twice,
    /// so Back seemed to do nothing; a page equal to the one on top is refused.
    func push(_ r: Route) {
        if path.last != r { path.append(r) }
    }

    func select(_ t: Tab) {
        if tab == t { path.removeAll() } else { tab = t; path.removeAll() }
    }

    // MARK: add-ons

    /// One add-on's manifest: from the cache; nil straight away for a recent miss; else the
    /// fetch already out for it, or a new one. The caller waits at most `seconds` (and not at
    /// all once it is cancelled); the fetch is never cut short by that, and lands for the next.
    func manifest(for addon: Addon, within seconds: Double = .infinity) async -> ManifestInfo? {
        let u = addon.manifestUrl
        if let m = manifestCache[u] { return m }
        if let miss = manifestMisses[u], Date().timeIntervalSince(miss.at) < AppModel.missWindow(miss.count) { return nil }
        let load: Task<ManifestInfo?, Never>
        if let out = manifestLoads[u] {
            load = out
        } else {
            let stremio = stremio
            load = Task { [weak self] in
                let got = try? await stremio.loadManifest(u)
                self?.manifestLanded(u, got)
                return got
            }
            manifestLoads[u] = load
        }
        return await Patience.value(of: load, within: seconds) ?? nil
    }

    private func manifestLanded(_ u: String, _ m: ManifestInfo?) {
        manifestLoads[u] = nil
        if let m = m { manifestCache[u] = m; manifestMisses[u] = nil }
        else { manifestMisses[u] = (Date(), (manifestMisses[u]?.count ?? 0) + 1) }
    }

    static func missWindow(_ misses: Int) -> TimeInterval {
        min(missForAtMost, missFor * pow(2, Double(max(0, min(misses, 10) - 1))))
    }

    /// Every add-on's manifest at once, in the add-ons' order; nil where one did not answer —
    /// or had not within `seconds`. An add-on asleep on a free host takes up to the whole 20 s
    /// timeout to answer, and every page used to wait for it before asking anyone for anything.
    /// Now a page takes what came in time, and the late one lands in the cache for the next.
    func manifests(for list: [Addon], within seconds: Double = 4) async -> [ManifestInfo?] {
        await withTaskGroup(of: (Int, ManifestInfo?).self) { group in
            for (i, a) in list.enumerated() { group.addTask { (i, await self.manifest(for: a, within: seconds)) } }
            var out = [ManifestInfo?](repeating: nil, count: list.count)
            for await (i, m) in group { out[i] = m }
            return out
        }
    }

    /// The viewer pressed Try again: ask the add-ons that missed straight away.
    func forgetMisses() { manifestMisses.removeAll() }

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
        manifestCache[url] = m; manifestMisses[url] = nil
        saveAddons(addons + [m.addon])
        say("Added \(m.addon.name).")
        return nil
    }

    private func syncApplied(_ keys: Set<String>) {
        if keys.contains("addons") { addons = addonStore.all(); manifestCache.removeAll(); manifestMisses.removeAll(); invalidateHome() }
        if keys.contains("progress") { progressVersion += 1 }
        if keys.contains("library") { libraryVersion += 1 }
    }

    // MARK: Home

    func invalidateHome() { homeSig = nil; Task { await loadHome() } }

    /// Home's Try again — and Discover's, which is built from the same catalogs.
    func retryHome() { forgetMisses(); catalogEpoch += 1; invalidateHome() }

    /// Each add-on on its own track: the moment its manifest is in, its catalogs are asked, and
    /// each row paints as it arrives, in the add-ons' order. Home used to wait for EVERY
    /// manifest first, so one add-on asleep on a free host blanked it for the full timeout;
    /// now that one's rows simply join when it wakes.
    func loadHome() async {
        let active = activeAddons
        let sig = active.map(\.manifestUrl).joined(separator: "\n")
        if sig == homeSig && !homeRows.isEmpty { return }
        homeSig = sig
        homeSeq += 1
        let seq = homeSeq
        homeLoading = true; homeFailed = false
        let stremio = stremio
        let cap = 24                                            // catalogs on Home, at most
        var catalogs = [[CatalogRef]](repeating: [], count: active.count)
        var rows = [[CatalogRow?]](repeating: [], count: active.count)
        var misses = 0, asked = 0, painted = false
        func paint() {
            homeRows = Array(rows.joined().compactMap { $0 }.prefix(cap))
            painted = true
        }
        await withTaskGroup(of: AddonStep.self) { group in
            for (i, a) in active.enumerated() { group.addTask { .manifest(i, await self.manifest(for: a)) } }
            while let step = await group.next() {
                guard seq == homeSeq else { group.cancelAll(); return }
                switch step {
                case .manifest(let i, let m):
                    guard let m = m else { misses += 1; continue }
                    let want = Array(m.catalogs.filter(\.browsable).prefix(cap))
                    catalogs[i] = want
                    rows[i] = Array(repeating: nil, count: want.count)
                    asked += want.count
                    let base = active[i].base
                    for (j, c) in want.enumerated() {
                        group.addTask { .catalog(i, j, try? await stremio.loadCatalog(base: base, catalog: c)) }
                    }
                case .catalog(let i, let j, let items):
                    if let items = items, !items.isEmpty { rows[i][j] = CatalogRow(addon: active[i], catalog: catalogs[i][j], items: Array(items.prefix(30))) }
                    paint()
                }
            }
        }
        guard seq == homeSeq else { return }
        // nothing was asked — every catalog add-on switched off, or none answered: the old rows go
        if !painted { homeRows = [] }
        homeLoading = false
        // an offline launch fails every manifest: that is a failure to say, not a blank page
        homeFailed = homeRows.isEmpty && (asked > 0 || misses > 0)
        if homeFailed { homeSig = nil }
    }

    // MARK: meta

    /// The title's own add-on first, then every add-on that says it has meta for the id.
    func loadMeta(_ item: MetaItem, addonUrl: String) async -> (FullMeta, Addon)? {
        let active = activeAddons
        let origin = active.first { $0.manifestUrl == addonUrl }
        let others = active.filter { $0.manifestUrl != addonUrl }
        // the others' manifests come in while the title's own add-on is asked; a page with
        // nothing to show yet can afford to wait longer for them than a list can
        async let infos = manifests(for: others, within: 10)
        func usable(_ m: FullMeta?) -> Bool { m.map { !$0.name.isEmpty || !$0.videos.isEmpty } ?? false }
        if let o = origin, let meta = try? await stremio.loadFullMeta(base: o.base, type: item.type, id: item.id), usable(meta) {
            return (meta, o)
        }
        for (a, m) in zip(others, await infos) {
            guard let m = m, m.canMeta(item.type, item.id) else { continue }
            if let meta = try? await stremio.loadFullMeta(base: a.base, type: item.type, id: item.id), usable(meta) {
                return (meta, a)
            }
        }
        return nil
    }

    // MARK: streams

    /// Each add-on on its own track — its manifest, then its streams — so a section shows the
    /// moment its add-on answers and a dead one holds nobody up. Returns how many were asked and
    /// answered, and how many could not be reached (a manifest or a stream request that failed).
    func loadStreams(_ t: StreamsTarget, onSection: @escaping (StreamSection) -> Void) async -> (answered: Int, unreachable: Int) {
        let stremio = stremio
        var answered = 0, unreachable = 0
        await withTaskGroup(of: (Addon, Bool, [StreamItem]?).self) { group in
            for a in activeAddons {
                group.addTask {
                    guard let m = await self.manifest(for: a) else { return (a, false, nil) }
                    guard m.stream.has, a.manifestUrl == t.addonUrl || m.canStream(t.type, t.id) else { return (a, false, []) }
                    return (a, true, try? await stremio.loadStreams(base: a.base, type: t.type, id: t.id))
                }
            }
            for await (a, asked, streams) in group {
                guard let s = streams else { unreachable += 1; continue }
                if asked { answered += 1 }
                if !s.isEmpty { onSection(StreamSection(addon: a, streams: s)) }
            }
        }
        return (answered, unreachable)
    }

    /// Every subtitle add-on at once, and for no longer than eight seconds: the player attaches
    /// captions once the file is open AND this has answered, so one slow add-on must not hold
    /// the others back. Whatever arrived by then is what goes in, in the add-ons' order.
    func addonSubtitles(type: String, id: String) async -> [SubTrack] {
        let list = activeAddons
        let stremio = stremio
        let wait: UInt64 = 8_000_000_000
        return await withTaskGroup(of: (Int, [SubTrack])?.self) { group in
            for (i, a) in list.enumerated() {
                group.addTask {
                    guard let m = await self.manifest(for: a), m.canSubs(type, id),
                          let subs = try? await stremio.loadSubtitles(base: a.base, type: type, id: id) else { return (i, []) }
                    return (i, subs)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: wait)
                return nil
            }
            var got = [[SubTrack]](repeating: [], count: list.count)
            var left = list.count
            while left > 0, let next = await group.next() {
                guard let answer = next else { break }        // the wait ran out
                got[answer.0] = answer.1
                left -= 1
            }
            group.cancelAll()                                 // the requests still out are dropped
            return got.flatMap { $0 }
        }
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

extension AppModel {
    /// `nebula://play?mpd=<address>&t=<title>` — the hand-off link the other clients use — and
    /// an add-on's `stremio://` install link.
    func handle(url: URL) {
        if url.scheme == "stremio" {
            tab = .addons; path.removeAll()
            Task { if let e = await installAddon(url.absoluteString) { say(e, error: true) } }
            return
        }
        guard url.scheme == "nebula", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let address = q["mpd"] ?? q["url"], !address.isEmpty else { return }
        let title = q["t"].flatMap { $0.isEmpty ? nil : $0 } ?? "Nebula"
        var s = StreamItem(name: "", title: "", url: ClearKey.cleanUrl(address))
        s.clearKeys = ClearKey.fromFragment(address)
        let item = MetaItem(id: "", type: "link", name: title)
        play(s, target: StreamsTarget(type: "link", id: "", item: item, addonUrl: ""), from: nil)
    }
}
