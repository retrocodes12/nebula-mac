import Foundation

/// One resume point per playable item, keyed "<type>:<id>". For a series that id is the episode
/// id, so every episode resumes on its own. Finished items keep a `done` tombstone so episode
/// lists can tick them off.
///
/// The record is the shared player's, field for field, and positions are SECONDS as they are on
/// the wire — one profile spans the TV, the phone and this Mac.
public struct ProgressRec: Equatable, Sendable {
    public var type: String
    public var id: String
    public var name = ""
    public var poster: String?
    public var shape = "poster"
    /// The backdrop, for the wide Continue watching card (the web player writes it; Android does not).
    public var back: String?
    public var addonUrl = ""
    public var pos: Double = 0
    public var dur: Double = 0
    public var done = false
    /// Removed from Continue watching — a tombstone, not a delete, so a synced device still
    /// holding the old position cannot push it straight back.
    public var dismissed = false
    /// Ticked off by hand rather than watched. A claim about the past, so the series cursor may
    /// move forwards on it but never backwards.
    public var hand = false
    public var at: Int64 = 0

    public init(type: String, id: String) { self.type = type; self.id = id }

    public var fraction: Double { dur > 0 ? min(1, max(0, pos / dur)) : 0 }

    init?(wire r: JSONObject) {
        guard let id = r.text("id") else { return nil }
        type = r.str("type"); self.id = id
        name = r.str("name"); poster = r.text("poster"); shape = r.text("shape") ?? "poster"; back = r.text("back")
        addonUrl = r.str("addonUrl"); pos = r.num("pos"); dur = r.num("dur")
        done = r.bool("done"); dismissed = r.bool("dismissed"); hand = r.bool("hand"); at = r.int64("at")
    }

    /// The wire shape: a tombstone carries nothing but what it is.
    var wire: JSONObject {
        var w: JSONObject = ["type": type, "id": id, "at": at]
        if done { w["done"] = true; if hand { w["hand"] = true } }
        else if dismissed { w["dismissed"] = true }
        else {
            w["name"] = name; w["poster"] = poster ?? ""; w["shape"] = shape; w["back"] = back ?? ""
            w["addonUrl"] = addonUrl; w["pos"] = pos; w["dur"] = dur
        }
        return w
    }
}

public final class ProgressStore: @unchecked Sendable {
    public static let maxRecords = 400
    public static let minPos: Double = 15          // below this it isn't worth resuming
    public static let endGap: Double = 60          // within this of the end counts as finished

    let store: Store
    private let lock = NSLock()
    /// Held across a whole read-change-write (`mutate`).
    private let writeLock = NSLock()
    private var cache: [String: ProgressRec]?
    public var onChange: (() -> Void)?
    /// Add-ons switched off in the list; their titles stay out of Continue watching.
    public var disabledAddons: () -> Set<String> = { [] }

    public init(store: Store) { self.store = store }

    public static func key(_ type: String, _ id: String) -> String { "\(type):\(id)" }

    public func all() -> [String: ProgressRec] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var m: [String: ProgressRec] = [:]
        for (k, v) in store.object("progress") {
            if let o = v as? JSONObject, let r = ProgressRec(wire: o) { m[k] = r }
        }
        cache = m
        return m
    }

    /// Read, change and write back as ONE step. Playback, a mark and a sync merge can land at
    /// the same moment on different threads; each used to read its own copy, and the last write
    /// threw away what the others had just written. `body` says whether it changed anything;
    /// only then is the store written and, with `notify`, the change announced (for sync).
    public func mutate(notify: Bool = true, _ body: (inout [String: ProgressRec]) -> Bool) {
        writeLock.lock()
        var m = all()
        let changed = body(&m)
        if changed { persist(m) }
        writeLock.unlock()
        if changed && notify { onChange?() }
    }

    private func persist(_ input: [String: ProgressRec]) {
        var m = input
        if m.count > ProgressStore.maxRecords {
            // What dies first matters. A mark carries `at = now`, so a season ticked off by hand
            // is the newest thing here and an oldest-first trim would take a LIVE resume point —
            // a position the viewer cannot get back. Stale tombstones go first, then ticks, and a
            // resume point is the last thing dropped.
            let now = nowMs()
            func rank(_ r: ProgressRec) -> Int {
                if r.dismissed { return now - r.at > 180 * 24 * 3_600_000 ? 0 : 2 }
                return r.done ? 2 : 3
            }
            let doomed = m.sorted { a, b in
                let ra = rank(a.value), rb = rank(b.value)
                return ra != rb ? ra < rb : a.value.at < b.value.at
            }.prefix(m.count - ProgressStore.maxRecords)
            for d in doomed { m[d.key] = nil }
        }
        lock.lock(); cache = m; lock.unlock()
        var o: JSONObject = [:]
        for (k, r) in m { o[k] = r.wire }
        store.setObject("progress", o)
    }

    public func get(_ type: String, _ id: String) -> ProgressRec? { all()[ProgressStore.key(type, id)] }

    /// Where playback of (type, id) should start, in seconds — 0 means the beginning.
    public func resumeAt(_ type: String, _ id: String) -> Double {
        guard let r = get(type, id), !r.done, !r.dismissed, r.pos > 0, r.dur > 0 else { return 0 }
        if r.pos < ProgressStore.minPos || r.pos > r.dur - ProgressStore.endGap { return 0 }
        return r.pos
    }

    public func note(_ rec: ProgressRec) {
        if rec.id.isEmpty { return }
        let k = ProgressStore.key(rec.type, rec.id)
        mutate { m in
            if rec.done || (rec.dur > 0 && rec.pos > rec.dur - ProgressStore.endGap) {
                var t = ProgressRec(type: rec.type, id: rec.id); t.done = true; t.at = nowMs()
                m[k] = t
                return true
            }
            if rec.pos < ProgressStore.minPos {            // rewound to the top — forget it
                guard let cur = m[k], !cur.done, !cur.dismissed else { return false }
                var t = ProgressRec(type: rec.type, id: rec.id); t.dismissed = true; t.at = nowMs()
                m[k] = t
                return true
            }
            var r = rec; r.at = nowMs()
            m[k] = r
            return true
        }
    }

    /// Tick something off by hand: the SAME `done` record that playing it to the end leaves, so
    /// the tick, the series cursor and Continue watching all agree.
    public func markWatched(_ type: String, _ id: String) {
        if id.isEmpty { return }
        let k = ProgressStore.key(type, id)
        mutate { m in
            // `hand` means "no playback ever happened here". Ticking off the episode you are
            // part-way through is you finishing it, not a claim about the past — stamping that
            // `hand` would throw away the only evidence of where you are.
            let real = m[k].map { !$0.dismissed && ($0.done || ($0.pos > 0 && $0.dur > 0)) } ?? false
            var t = ProgressRec(type: type, id: id); t.done = true; t.hand = !real; t.at = nowMs()
            m[k] = t
            return true
        }
    }

    /// Undo that, or a part-way position: the tombstone every list reads as "never started".
    public func markUnwatched(_ type: String, _ id: String) {
        if id.isEmpty { return }
        mutate { m in
            var t = ProgressRec(type: type, id: id); t.dismissed = true; t.at = nowMs()
            m[ProgressStore.key(type, id)] = t
            return true
        }
    }

    public func clear(_ type: String, _ id: String) {
        if get(type, id) != nil { markUnwatched(type, id) }
    }

    /// Replace the whole store after a sync merge (no re-push side effects).
    public func replaceAll(_ m: [String: ProgressRec]) { mutate(notify: false) { $0 = m; return true } }

    public func wireDoc() -> JSONObject {
        var o: JSONObject = [:]
        for (k, r) in all() { o[k] = r.wire }
        return o
    }

    /// The twenty most recent things worth resuming, newest first.
    public func continueList() -> [ProgressRec] {
        let off = disabledAddons()
        return all().values
            .filter { !$0.done && !$0.dismissed && $0.pos >= ProgressStore.minPos && $0.dur > 0 && $0.pos <= $0.dur - ProgressStore.endGap }
            .filter { $0.addonUrl.isEmpty || !off.contains($0.addonUrl) }
            .sorted { $0.at > $1.at }
            .prefix(20).map { $0 }
    }
}

/// Where a viewer is in a series: what to watch next, and which season to open on.
public struct SeriesCursor: Equatable, Sendable {
    public var upNext: Episode?
    public var seat: Episode

    /// A mark says "I saw THIS one" and nothing else: the cursor follows the newest episode that
    /// was really played, then steps over any run of hand-ticked episodes after it. Specials sort
    /// last, and only a viewer who has touched them is walked into them.
    public static func find(type: String, videos: [Episode], progress all: [String: ProgressRec]) -> SeriesCursor? {
        let flat = videos.sorted { a, b in
            if (a.season == 0) != (b.season == 0) { return b.season == 0 }
            if a.season != b.season { return a.season < b.season }
            return (a.episode ?? 0) < (b.episode ?? 0)
        }
        guard !flat.isEmpty else { return nil }
        let last = flat.count - 1
        var played: ProgressRec?
        var playedIdx = -1
        var anyHand = false, inSpecials = false
        for (i, e) in flat.enumerated() {
            guard let r = all[ProgressStore.key(type, e.id)], !r.dismissed else { continue }
            if e.season == 0 { inSpecials = true }
            if r.hand { if r.done { anyHand = true }; continue }
            if !r.done && !(r.pos >= ProgressStore.minPos && r.dur > 0) { continue }
            if played == nil || r.at > played!.at { played = r; playedIdx = i }
        }
        if playedIdx < 0 && !anyHand { return nil }
        var lastReal = last
        while lastReal > 0 && flat[lastReal].season == 0 { lastReal -= 1 }
        let hasReal = flat[lastReal].season != 0
        let seat = hasReal ? lastReal : last
        var i = playedIdx < 0 ? 0 : (played?.done == true ? playedIdx + 1 : playedIdx)
        while i <= last {
            guard let r = all[ProgressStore.key(type, flat[i].id)], r.hand, r.done else { break }
            i += 1
        }
        if i > last || (hasReal && !inSpecials && flat[i].season == 0) { return SeriesCursor(upNext: nil, seat: flat[seat]) }
        return SeriesCursor(upNext: flat[i], seat: flat[i])
    }
}
