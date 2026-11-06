import Foundation

/// A watch party's playback: the newest state anyone sent. `pos` is seconds (on a live stream: seconds behind the live
/// edge); `at` is the relay's clock in ms (this device's own on a v1 relay: arrival − age).
public struct PartyState: Equatable, Sendable {
    public var playing: Bool
    public var pos: Double
    public var live: Bool
    public var rate: Double
    public var waiting: Bool
    public var at: Int64
    public var seq: Int64
    public var by: String
    public var name: String
    public init(playing: Bool, pos: Double, live: Bool = false, rate: Double = 1, waiting: Bool = false, at: Int64, seq: Int64 = 0, by: String = "", name: String = "") {
        self.playing = playing; self.pos = pos; self.live = live; self.rate = rate; self.waiting = waiting
        self.at = at; self.seq = seq; self.by = by; self.name = name
    }
}

public struct PartyMember: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: Bool
    public var s: String
    public var k: String
    public var behind: Int?
    public var v: Int
    public init(id: String, name: String, host: Bool, s: String, k: String = "", behind: Int? = nil, v: Int = 2) {
        self.id = id; self.name = name; self.host = host; self.s = s; self.k = k; self.behind = behind; self.v = v
    }
}

public struct PartyChatLine: Equatable, Identifiable, Sendable {
    public var id: String { cid ?? "m\(num)" }
    public var num: Int64
    public var by: String
    public var name: String
    public var text: String
    public var cid: String?
    public var pend = false
    public var fail = false
    public init(num: Int64, by: String, name: String, text: String, cid: String? = nil, pend: Bool = false) {
        self.num = num; self.by = by; self.name = name; self.text = text; self.cid = cid; self.pend = pend
    }
}

/// What a party watches: the host's link (unless it keeps it to itself) and the title, so viewers get subtitles,
/// progress — and can look the file up in their own add-ons.
public struct PartyStreamDesc: Equatable, Sendable {
    public var url: String
    public var title: String
    public var subs: [SubTrack]
    public var type: String?
    public var id: String?
    public var name: String?
    public var poster: String?
    public var addonUrl: String?
    public var file: String?
    public var hash: String?
    public var share: Bool
    /// Decryption keys the host's link needs (kid → key, 32 hex digits each) — they travel with the link only.
    public var keys: [String: String]
    public init(url: String, title: String, subs: [SubTrack] = [], type: String? = nil, id: String? = nil, name: String? = nil,
                poster: String? = nil, addonUrl: String? = nil, file: String? = nil, hash: String? = nil, share: Bool = true,
                keys: [String: String] = [:]) {
        self.url = url; self.title = title; self.subs = subs; self.type = type; self.id = id; self.name = name
        self.poster = poster; self.addonUrl = addonUrl; self.file = file; self.hash = hash; self.share = share; self.keys = keys
    }
    public var key: String { PartySync.keyOf(type, id, url) }

    /// The wire shape (the relay drops the address when `share` is false and the title names itself).
    public func wire() -> [String: Any] {
        var o: [String: Any] = ["title": title]
        if share || (type ?? "").isEmpty || (id ?? "").isEmpty {
            o["url"] = url
            if !subs.isEmpty { o["subs"] = subs.map { ["url": $0.url, "lang": $0.lang] } }
            if !keys.isEmpty { o["keys"] = keys }
        } else { o["share"] = false }
        if let v = type { o["type"] = v }
        if let v = id { o["id"] = v }
        if let v = name { o["name"] = v }
        if let v = poster { o["poster"] = v }
        if let v = addonUrl { o["addonUrl"] = v }
        if let v = file, !v.isEmpty { o["file"] = String(v.prefix(300)) }
        if let v = hash, v.count == 40 { o["hash"] = v }
        return o
    }
    /// From the wire; nil when it names no web address and no title to look up.
    public static func from(_ o: [String: Any]) -> PartyStreamDesc? {
        func s(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let raw = s("url") ?? ""
        let url = raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") ? raw : ""
        let share = (o["share"] as? Bool) != false
        var subs: [SubTrack] = []
        for x in (o["subs"] as? [[String: Any]]) ?? [] {
            if let u = x["url"] as? String, u.lowercased().hasPrefix("http") { subs.append(SubTrack(url: u, lang: (x["lang"] as? String) ?? "")) }
        }
        var keys: [String: String] = [:]
        let hex = { (x: String) in x.count == 32 && x.allSatisfy(\.isHexDigit) }
        for (k, v) in (o["keys"] as? [String: Any]) ?? [:] { if let v = v as? String, hex(k), hex(v) { keys[k] = v } }
        let d = PartyStreamDesc(url: url, title: s("title") ?? "Watch party", subs: subs, type: s("type"), id: s("id"), name: s("name"),
                                poster: s("poster"), addonUrl: s("addonUrl"), file: s("file"), hash: s("hash"), share: share, keys: keys)
        if url.isEmpty && (share || d.type == nil || d.id == nil) { return nil }
        return d
    }
}

/// The watch party's rules — the same numbers and sentences as the shared player and Android (party-2026-11-06.md).
public enum PartySync {
    public static let seek = 1.5, nudgeOn = 0.3, nudgeOff = 0.1, nudge = 0.05, pausedTol = 0.5, rejoin = 2.0
    public static let waitMax: Int64 = 15_000, resumeGrace: Int64 = 3_000, heartbeat: Int64 = 4_000

    /// The shortest round trip wins; a stale best gives way after 5 minutes.
    public struct Clock: Sendable {
        public private(set) var off: Int64 = 0
        private var rtt: Int64 = -1
        private var at: Int64 = 0
        public init() {}
        public mutating func sample(sentAt: Int64, server: Int64, now: Int64) {
            guard sentAt > 0, server > 0 else { return }
            let r = max(0, now - sentAt)
            if rtt < 0 || r <= rtt + 30 || now - at > 300_000 {
                if rtt < 0 || r <= rtt || now - at > 300_000 { rtt = r; at = now }
                off = server + r / 2 - now
            }
        }
    }

    public static func keyOf(_ type: String?, _ id: String?, _ url: String) -> String {
        if let t = type, !t.isEmpty, let i = id, !i.isEmpty { return "\(t):\(i)" }
        return url
    }
    public static func seriesIdOf(_ id: String) -> String {
        let p = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if p.count >= 2, !p[0].hasPrefix("tt"), p[0].allSatisfy({ $0.isLetter }) { return p[0] + ":" + p[1] }
        return p.first ?? id
    }
    public static func sameShow(_ aType: String?, _ aId: String?, _ bType: String?, _ bId: String?) -> Bool {
        guard let a = aId, !a.isEmpty, let b = bId, !b.isEmpty, aType == bType else { return false }
        return a == b || seriesIdOf(a) == seriesIdOf(b)
    }

    public static func expect(_ s: PartyState, now: Int64) -> Double {
        s.playing ? s.pos + Double(max(0, now - s.at)) / 1000 * s.rate : s.pos
    }

    public enum Move: Equatable { case hold(Double), nudge(Double), seek(by: Double, rate: Double) }
    /// `err` = seconds this device is behind the party (negative = ahead).
    public static func move(err: Double, rate: Double, nudging: Bool) -> Move {
        let a = abs(err)
        if a > seek { return .seek(by: err, rate: rate) }
        if a > nudgeOn || (nudging && a > nudgeOff) { return .nudge(rate * (err > 0 ? 1 + nudge : 1 - nudge)) }
        return .hold(rate)
    }
    public static func isNudge(_ r: Double, of partyRate: Double) -> Bool {
        abs(r - partyRate * (1 + nudge)) < 0.001 || abs(r - partyRate * (1 - nudge)) < 0.001
    }

    public static func notice(_ prev: PartyState?, _ s: PartyState) -> String? {
        guard let p = prev, !p.waiting, !s.waiting, !s.name.isEmpty, p.live == s.live else { return nil }
        if p.playing != s.playing { return s.name + (s.playing ? " resumed" : " paused") }
        if abs(p.rate - s.rate) > 0.01 { return s.name + " changed the speed to " + rateText(s.rate) + "×" }
        if !s.live && abs(s.pos - expect(p, now: s.at)) > 2 { return s.name + " skipped to " + timeText(s.pos) }
        return nil
    }
    public static func rateText(_ r: Double) -> String { r == r.rounded() ? String(Int(r)) : String(format: "%g", r) }
    public static func timeText(_ sec: Double) -> String {
        let t = max(0, Int(sec)), h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    public static func gapLabel(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        if s < 60 { return "\(s) s" }
        let m = Int((Double(s) / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
    public static func behindReported(_ gap: Double) -> Int { max(5, Int((max(0, gap) / 5).rounded()) * 5) }

    public static func statusLabel(_ m: PartyMember) -> String {
        switch m.s {
        case "ready": return "Watching"
        case "buffering": return "Buffering"
        case "loading": return "Loading"
        case "choosing": return "Choosing a source"
        case "away": return "Watching something else"
        case "behind": return gapLabel(Double(m.behind ?? 0)) + " behind"
        default: return ""
        }
    }

    public static func waiters(_ members: [PartyMember], me: String, key: String, ignore: Set<String>) -> [PartyMember] {
        members.filter { $0.id != me && $0.k == key && ($0.s == "loading" || $0.s == "buffering") && !ignore.contains($0.id) }
    }

    /// The same file in another add-on's answer: the release, then the file name.
    public static func matchOwn(_ rows: [StreamItem], file: String?) -> StreamItem? {
        guard let f = file, !f.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let key = ReleaseKey.of(f)
        if !key.isEmpty, let hit = rows.first(where: { let n = ReleaseKey.fileName($0); return !n.isEmpty && ReleaseKey.of(n) == key }) { return hit }
        let bare = (f as NSString).lastPathComponent.lowercased()
        return rows.first { (ReleaseKey.fileName($0) as NSString).lastPathComponent.lowercased() == bare }
    }
}
