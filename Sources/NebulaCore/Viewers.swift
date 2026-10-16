import Foundation

/// One of an account's profiles: "a" (the first, always there) or "b".
public struct Viewer: Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var av: String
    public init(id: String, name: String, av: String) { self.id = id; self.name = name; self.av = av }
}

/// Who's watching (0.5.0; the shared player's `viewers`, the same wire). An account holds up to two profiles. Each keeps
/// its own watch history — Continue Watching, resume points, ticks, My List — and its own add-ons; settings stay the
/// account's. The first profile's IS the account's as it always was ("progress", "library", "addons"), so nothing moves
/// for anyone; the second's sits beside it ("progress_b", "library_b", "addons_b") on this device and in the cloud. The list is synced
/// (`viewers`: {at, list:[{id, name, av}]}, newest wins); which profile this device is on is not.
public final class Viewers: @unchecked Sendable {
    static let perProfile: Set<String> = ["progress", "library", "addons", "addons_sync"]
    let store: Store

    public init(store: Store) { self.store = store }

    /// "a" or "b": the profile this device is on.
    public var current: String { store.string("viewer") == "b" ? "b" : "a" }
    public func setCurrent(_ id: String) { store.set("viewer", id == "b" ? "b" : "a") }

    /// The name a per-profile store goes under for the profile this device is on.
    public func key(_ k: String) -> String { Viewers.key(k, viewer: current) }
    public static func key(_ k: String, viewer: String) -> String { viewer == "b" && perProfile.contains(k) ? k + "_b" : k }

    public func doc() -> JSONObject { store.object("viewers_v1") }
    public func list() -> [Viewer] { Viewers.parse(doc()) }

    /// The profiles, the first always there, at most two, in order.
    public static func parse(_ d: JSONObject) -> [Viewer] {
        var out: [String: Viewer] = [:]
        for case let o as JSONObject in d.arr("list") {
            let id = o.str("id")
            if (id == "a" || id == "b") && out[id] == nil { out[id] = Viewer(id: id, name: String(o.str("name").prefix(24)), av: o.str("av")) }
        }
        if out["a"] == nil { out["a"] = Viewer(id: "a", name: "", av: "") }
        return out.values.sorted { $0.id < $1.id }
    }

    /// A new list, stamped now (it goes up with `viewers`).
    public func setList(_ l: [Viewer]) {
        let arr: [Any] = l.map { ["id": $0.id, "name": String($0.name.prefix(24)), "av": $0.av] as JSONObject }
        store.setObject("viewers_v1", ["at": nowMs(), "list": arr])
    }

    /// The synced list: newest wins. (A second profile removed elsewhere: the caller moves this device back to the first.)
    public func merge(_ remote: JSONObject) -> (changed: Bool, localNewer: Bool) {
        let ra = remote.int64("at"), la = doc().int64("at")
        guard remote["list"] is [Any] else { return (false, la > 0) }
        if ra > la {
            store.setObject("viewers_v1", ["at": ra, "list": remote.arr("list")])
            if list().count < 2 && current == "b" { setCurrent("a") }
            return (true, false)
        }
        return (false, la > ra)
    }
}
