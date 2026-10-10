import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where an episode's recap, opening titles and closing credits fall. Nebula Cloud answers
/// `/v1/skip?id=tt…:S:E` from a community timestamp database and caches it; the request carries
/// the episode id and nothing else. Asked once per episode, only for series episodes with an
/// IMDb-shaped id, and never when the setting is Off. The same rules as the shared player's
/// `skipState` and Android's `SkipSegments`.
public enum SkipSegments {
    public struct Seg: Equatable, Sendable {
        public var start: Double
        public var end: Double
    }

    public struct Segs: Equatable, Sendable {
        public var recap: Seg?
        public var intro: Seg?
        public var outro: Seg?
        public init(recap: Seg? = nil, intro: Seg? = nil, outro: Seg? = nil) { self.recap = recap; self.intro = intro; self.outro = outro }
    }

    /// Off / show a Skip button / skip by itself — the shared player's pref `skip`.
    public static let modes = ["button", "auto", "off"]

    public static func eligible(type: String, id: String) -> Bool {
        type == "series" && id.range(of: #"^tt\d+:\d+:\d+$"#, options: .regularExpression) != nil
    }

    public static func parse(_ o: JSONObject) -> Segs {
        func seg(_ k: String) -> Seg? {
            guard let s = o.obj(k), let a = (s["start"] as? NSNumber)?.doubleValue, let b = (s["end"] as? NSNumber)?.doubleValue,
                  a.isFinite, b.isFinite, a >= 0, b - a >= 1 else { return nil }
            return Seg(start: a, end: b)
        }
        return Segs(recap: seg("recap"), intro: seg("intro"), outro: seg("outro"))
    }

    /// The recap or intro `pos` sits inside, with at least a second left to skip.
    public static func at(_ segs: Segs?, _ pos: Double) -> (kind: String, seg: Seg)? {
        guard let s = segs else { return nil }
        if let r = s.recap, pos >= r.start, pos < r.end - 1 { return ("recap", r) }
        if let i = s.intro, pos >= i.start, pos < i.end - 1 { return ("intro", i) }
        return nil
    }

    /// The closing credits have started.
    public static func inOutro(_ segs: Segs?, _ pos: Double) -> Bool {
        guard let o = segs?.outro else { return false }
        return pos >= o.start
    }

    public static func label(_ kind: String) -> String { kind == "recap" ? "Skip recap" : "Skip intro" }
    public static func note(_ kind: String) -> String { kind == "recap" ? "Skipped the recap" : "Skipped the intro" }

    private static let cache = Cache<Segs>()

    /// nil when the cloud could not be reached — asked again next time.
    public static func load(_ id: String, base: String = Cloud.defaultBase, transport: Transport = URLSessionTransport(timeout: 10)) async -> Segs? {
        if let c = cache.get(id) { return c }
        var comps = URLComponents(string: base + "/v1/skip")
        comps?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = comps?.url else { return nil }
        var r = URLRequest(url: url)
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, code) = try? await transport.send(r), (200...299).contains(code), let o = JSON.object(data) else { return nil }
        let segs = parse(o)
        cache.put(id, segs)
        return segs
    }
}

/// A small thread-safe memo for this run of the app.
final class Cache<V>: @unchecked Sendable {
    private var items: [String: V] = [:]
    private let lock = NSLock()
    private let limit: Int
    init(limit: Int = 300) { self.limit = limit }
    func get(_ k: String) -> V? { lock.lock(); defer { lock.unlock() }; return items[k] }
    func put(_ k: String, _ v: V) {
        lock.lock(); defer { lock.unlock() }
        if items.count >= limit { items.removeAll() }
        items[k] = v
    }
}
