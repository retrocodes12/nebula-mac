import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A title's Universe: what it follows, what follows it, its spin-offs, what it spun off from,
/// its remakes. Nebula Cloud answers `/v1/universe?id=tt…` from a film database and keeps each
/// answer a week; this run of the app keeps it too, so a title page asks at most once. The
/// request carries the title id and nothing else. The shared player's `detUniverse`.
public enum Universe {
    public struct Item: Equatable, Identifiable, Sendable {
        public var rel: String
        public var meta: MetaItem
        public var id: String { meta.id }
        public var label: String { Universe.label(rel) }
    }

    /// The title's own tt… id (an episode id gives its show's), or nil when it has none.
    public static func idOf(_ id: String) -> String? {
        guard let r = id.range(of: #"^tt\d{5,10}(?=$|:)"#, options: .regularExpression) else { return nil }
        return String(id[r])
    }

    public static func label(_ rel: String) -> String {
        switch rel {
        case "follows": return "Follows"
        case "followed_by": return "Followed by"
        case "spin_off_from": return "Spin-off from"
        case "spin_off": return "Spin-off"
        case "remake_of": return "Remake of"
        case "remade_as": return "Remade as"
        default: return ""
        }
    }

    public static func parse(_ o: JSONObject) -> [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for x in o.objs("items") {
            let tid = x.str("id"), name = x.str("name")
            guard idOf(tid) == tid, !name.isEmpty, seen.insert(tid).inserted else { continue }
            let type = x.str("type") == "series" ? "series" : "movie"
            let year = x.int("year"), end = x.int("end")
            let span: String? = year <= 0 ? nil : (type == "series" && end > 0 && end != year ? "\(year)–\(end)" : String(year))
            out.append(Item(rel: x.str("rel"), meta: MetaItem(id: tid, type: type, name: name, poster: x.text("poster"), releaseInfo: span)))
        }
        return out
    }

    private static let cache = Cache<[Item]>()

    public static func cached(_ id: String) -> [Item]? { cache.get(id) }

    /// nil when the cloud could not be reached — asked again the next time the page opens.
    public static func load(_ id: String, base: String = Cloud.defaultBase, transport: Transport = URLSessionTransport(timeout: 10)) async -> [Item]? {
        if let c = cache.get(id) { return c }
        var comps = URLComponents(string: base + "/v1/universe")
        comps?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = comps?.url else { return nil }
        var r = URLRequest(url: url)
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, code) = try? await transport.send(r), (200...299).contains(code), let o = JSON.object(data) else { return nil }
        let items = parse(o)
        cache.put(id, items)
        return items
    }
}
