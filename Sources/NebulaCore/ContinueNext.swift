import Foundation

/// Continue watching, Nuvio's way (11-05; the shared player's `continueList` + `nu*`, Android's `ContinueNext.kt`).
/// ONE card per show — its newest resume point, or, once the newest thing played there is finished, the episode after
/// it ("Up next", worked out by `SeriesCursor` over the show's episode list) — and every film part-way through.
///
/// The episode list lives with the add-on, so the app keeps an `Answer` per show (`NextUpAnswers`) against the show's
/// `sig` — the newest `at` of any of its records, so a mark, an unmark or a play works it out again. A removed Up next
/// is a `nextup:<show>` dismissed record in the progress store (it syncs) and stays off until another episode of the
/// show is finished.
public enum ContinueNext {
    public static let nextupType = "nextup"
    /// A kept answer is asked again after this (a new episode may have aired).
    public static let ttlMs: Int64 = 12 * 3_600_000
    /// A failed ask is tried again after this.
    public static let failMs: Int64 = 10 * 60_000
    static let soonMs: Int64 = 7 * 86_400_000

    public struct Ep: Equatable, Sendable {
        public var id: String
        public var s: Int
        public var e: Int?
        public var name: String
        public var thumb: String?
        public var rel: String?
        public init(id: String, s: Int, e: Int?, name: String, thumb: String?, rel: String?) {
            self.id = id; self.s = s; self.e = e; self.name = name; self.thumb = thumb; self.rel = rel
        }
    }

    public struct Answer: Equatable, Sendable {
        public var sig: Int64
        public var t: Int64
        public var name = ""
        public var poster: String?
        public var back: String?
        public var addonUrl = ""
        /// The next episode is in the same season as the one before it.
        public var same = false
        public var ep: Ep?
        public init(sig: Int64, t: Int64) { self.sig = sig; self.t = t }
    }

    /// One show's records, gathered.
    public struct Show: Equatable, Sendable {
        public var id: String
        public var type: String
        public var sig: Int64 = 0
        /// The newest PLAYED record (a hand mark is a claim about the past, not where the viewer is).
        public var last: ProgressRec?
        /// The newest finish, played or marked.
        public var seedAt: Int64 = 0
        public var addonUrl = ""
        var urlAt: Int64 = 0
    }

    /// The row. Pure over its inputs — [answer] gives a show's kept Up next (nil while it is asked: [want] is told).
    public static func plan(all: [String: ProgressRec], off: Set<String>, nextOn: Bool, unaired: Bool, now: Int64,
                            answer: (Show) -> Answer?, want: (Show) -> Void) -> [ProgressRec] {
        var out: [ProgressRec] = []
        var shows: [String: Show] = [:]
        var order: [String] = []
        for r in all.values {
            if r.id.isEmpty || r.type == nextupType { continue }
            let sid = r.type == "series" ? Ids.seriesId(of: r.id) : ""
            if !sid.isEmpty && sid != r.id {
                if shows[sid] == nil { shows[sid] = Show(id: sid, type: r.type); order.append(sid) }
                var s = shows[sid]!
                s.sig = max(s.sig, r.at)
                defer { shows[sid] = s }
                if r.dismissed { continue }
                if !r.addonUrl.isEmpty && r.at >= s.urlAt { s.addonUrl = r.addonUrl; s.urlAt = r.at }
                if r.done {
                    s.seedAt = max(s.seedAt, r.at)
                    if !r.hand && (s.last.map { r.at > $0.at } ?? true) { s.last = r }
                    continue
                }
                if ProgressStore.resumable(r) && (s.last.map { r.at > $0.at } ?? true) { s.last = r }
                continue
            }
            if !ProgressStore.resumable(r) { continue }
            if !r.addonUrl.isEmpty && off.contains(r.addonUrl) { continue }
            out.append(r)
        }
        for sid in order {
            guard let s = shows[sid] else { continue }
            if !s.addonUrl.isEmpty && off.contains(s.addonUrl) { continue }
            if let last = s.last, !last.done { out.append(last); continue }     // the newest thing here is part-way
            if s.seedAt <= 0 || !nextOn { continue }
            if let nd = all[ProgressStore.key(nextupType, s.id)], nd.dismissed, nd.at >= s.seedAt { continue }
            let a = answer(s)
            if a == nil || a!.sig != s.sig || now - a!.t > ttlMs { want(s) }
            guard let got = a, got.sig == s.sig, let e = got.ep else { continue }
            // the episode after the one finished was started already (an older part-way record): that is the card
            let own = all[ProgressStore.key(s.type, e.id)]
            if ProgressStore.resumable(own) { out.append(own!); continue }
            if own?.done == true { continue }
            let rel = releasedMs(e.rel)
            let isOut = rel == nil || rel! <= now
            // not out yet: only with "Show episodes not out yet", and a new season only in its last week (Nuvio's rule)
            if !isOut && (!unaired || !(got.same || rel! - now <= soonMs)) { continue }
            var r = ProgressRec(type: s.type, id: e.id)
            r.name = got.name
            r.epName = e.name
            r.poster = got.poster
            r.back = e.thumb ?? got.back
            r.shape = "landscape"
            r.addonUrl = s.addonUrl.isEmpty ? got.addonUrl : s.addonUrl
            r.at = s.seedAt
            r.next = true
            r.seriesId = s.id
            r.seriesPoster = got.poster
            r.airs = isOut ? 0 : rel!
            r.fresh = isOut && rel != nil && rel! > s.seedAt
            out.append(r)
        }
        return Array(out.sorted { $0.at > $1.at }.prefix(20))
    }

    /// What a show's episode list says comes next for the records in [all].
    public static func answer(show s: Show, name: String, poster: String?, back: String?, videos: [Episode],
                              all: [String: ProgressRec], now: Int64) -> Answer {
        var a = Answer(sig: s.sig, t: now)
        a.name = name; a.poster = poster; a.back = back; a.addonUrl = s.addonUrl
        let flat = videos.sorted { x, y in
            if (x.season == 0) != (y.season == 0) { return y.season == 0 }
            if x.season != y.season { return x.season < y.season }
            return (x.episode ?? 0) < (y.episode ?? 0)
        }
        guard let up = SeriesCursor.find(type: s.type, videos: flat, progress: all)?.upNext,
              let i = flat.firstIndex(of: up) else { return a }
        a.same = i > 0 && flat[i - 1].season == up.season
        a.ep = Ep(id: up.id, s: up.season, e: up.episode, name: up.name, thumb: up.thumbnail, rel: up.released)
        return a
    }

    /// An episode's release time in ms (ISO date-time, or a bare date = that day's start in UTC), or nil.
    public static func releasedMs(_ s: String?) -> Int64? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return Int64(d.timeIntervalSince1970 * 1000) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t) { return Int64(d.timeIntervalSince1970 * 1000) }
        f.formatOptions = [.withFullDate]
        if let d = f.date(from: String(t.prefix(10))) { return Int64(d.timeIntervalSince1970 * 1000) }
        return nil
    }
}

/// The kept Up next answers, per profile (`nextup_a`, `nextup_b`), at most 60.
public final class NextUpAnswers: @unchecked Sendable {
    let store: Store
    public var viewers: Viewers?
    private let lock = NSLock()
    private var cache: [String: ContinueNext.Answer]?
    private var cacheKey: String?

    public init(store: Store) { self.store = store }
    /// Each profile its own document (not a synced key, so not in Viewers.perProfile).
    private var key: String { "nextup_" + (viewers?.current ?? "a") }

    public func get(_ id: String) -> ContinueNext.Answer? { lock.lock(); defer { lock.unlock() }; return load()[id] }

    public func put(_ items: [String: ContinueNext.Answer]) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        for (k, v) in items { m[k] = v }
        if m.count > 60 { for k in m.sorted(by: { $0.value.t < $1.value.t }).prefix(m.count - 60).map(\.key) { m[k] = nil } }
        cache = m
        var o: JSONObject = [:]
        for (k, a) in m {
            var w: JSONObject = ["sig": a.sig, "t": a.t, "name": a.name, "poster": a.poster ?? "", "back": a.back ?? "",
                                 "addonUrl": a.addonUrl, "same": a.same]
            if let e = a.ep {
                var ew: JSONObject = ["id": e.id, "s": e.s, "name": e.name, "thumb": e.thumb ?? "", "rel": e.rel ?? ""]
                if let n = e.e { ew["e"] = n }
                w["ep"] = ew
            }
            o[k] = w
        }
        store.setObject(key, o)
    }

    /// Lock held.
    private func load() -> [String: ContinueNext.Answer] {
        if let c = cache, cacheKey == key { return c }
        var m: [String: ContinueNext.Answer] = [:]
        for (k, v) in store.object(key) {
            guard let o = v as? JSONObject else { continue }
            var a = ContinueNext.Answer(sig: o.int64("sig"), t: o.int64("t"))
            a.name = o.str("name"); a.poster = o.text("poster"); a.back = o.text("back")
            a.addonUrl = o.str("addonUrl"); a.same = o.bool("same")
            if let e = o["ep"] as? JSONObject, let id = e.text("id") {
                let n = e["e"] as? NSNumber
                a.ep = ContinueNext.Ep(id: id, s: e.int("s"), e: n?.intValue, name: e.str("name"), thumb: e.text("thumb"), rel: e.text("rel"))
            }
            m[k] = a
        }
        cache = m; cacheKey = key
        return m
    }
}
