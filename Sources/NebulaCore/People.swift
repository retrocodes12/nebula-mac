import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A person's films and series: a cast member, a director or a writer pressed on a title page. Nebula Cloud answers
/// `/v1/person?n=<name>&t=tt…` (it finds who the name is through that title, from a public knowledge base, and keeps
/// each answer a week); this run of the app keeps it too. The request carries the name and the title id and nothing
/// else. Posters come from the catalogue's image host by title id; a person is shown by name. The shared player's
/// `personOpen`, Android's People.kt.
public enum People {
    public struct Item: Equatable, Identifiable, Sendable {
        public var meta: MetaItem
        /// What they did on it: "cast", "director", "writer" (one or more).
        public var roles: Set<String>
        public var id: String { meta.id }
    }
    public struct Person: Equatable, Sendable {
        public var id: String
        public var name: String
        public var items: [Item]
    }
    public enum Answer: Equatable, Sendable {
        case found(Person)
        /// Nobody by that name with film or series credits, or nothing to show.
        case none
        /// The cloud could not be reached or could not answer: asked again on Try again or the next visit.
        case failed
    }

    /// The filters, in order: All, then by kind of title, then by what they did.
    public static let allKinds: [(id: String, label: String)] = [("all", "All"), ("movie", "Films"), ("series", "Series"), ("director", "Directed"), ("writer", "Written")]

    public static func matches(_ i: Item, _ kind: String) -> Bool { kind == "all" || i.meta.type == kind || i.roles.contains(kind) }

    /// The filters worth offering: All, and each one that would change something; none when nothing would.
    public static func kinds(for items: [Item]) -> [(id: String, label: String)] {
        let l = allKinds.filter { k in
            if k.id == "all" { return true }
            let n = items.filter { matches($0, k.id) }.count
            return n > 0 && n < items.count
        }
        return l.count > 1 ? l : []
    }

    public static func key(_ name: String, _ tt: String?) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased() + "|" + (tt ?? "")
    }

    /// The cloud's answer as cards, or nil when it is not one.
    public static func parse(_ o: JSONObject) -> Person? {
        guard o["items"] is [Any] else { return nil }
        var seen = Set<String>()
        var items: [Item] = []
        for x in o.objs("items") {
            let tid = x.str("id"), name = x.str("name")
            guard tid.range(of: #"^tt\d{5,10}$"#, options: .regularExpression) != nil, !name.isEmpty, seen.insert(tid).inserted else { continue }
            let type = x.str("type") == "series" ? "series" : "movie"
            let year = x.int("year")
            items.append(Item(
                meta: MetaItem(id: tid, type: type, name: name, poster: "https://images.metahub.space/poster/medium/\(tid)/img",
                               releaseInfo: year > 0 ? String(year) : nil),
                roles: Set((x.strs("as") ?? []).filter { !$0.isEmpty })))
        }
        return Person(id: o.str("id"), name: o.str("name"), items: items)
    }

    private static let cache = Cache<Answer>(limit: 200)

    public static func cached(_ name: String, _ tt: String?) -> Answer? { cache.get(key(name, tt)) }

    public static func load(_ name: String, _ tt: String?, base: String = Cloud.defaultBase, transport: Transport = URLSessionTransport(timeout: 20)) async -> Answer {
        let k = key(name, tt)
        if let c = cache.get(k) { return c }
        var comps = URLComponents(string: base + "/v1/person")
        var q = [URLQueryItem(name: "n", value: name.trimmingCharacters(in: .whitespaces))]
        if let tt { q.append(URLQueryItem(name: "t", value: tt)) }
        comps?.queryItems = q
        guard let url = comps?.url else { return .failed }
        var r = URLRequest(url: url)
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, code) = try? await transport.send(r) else { return .failed }
        let a: Answer
        if code == 404 { a = .none }
        else if !(200...299).contains(code) { return .failed }
        else if let o = JSON.object(data), let p = parse(o) { a = p.items.isEmpty ? .none : .found(p) }
        else { return .failed }
        cache.put(k, a)
        return a
    }
}
