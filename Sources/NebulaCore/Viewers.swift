import Foundation

/// One of an account's profiles: "a" (the first, always there) or "b".
public struct Viewer: Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var av: String
    /// The profile's PIN (10-23), or nil. Every rewrite of the list carries it through.
    public var lock: PinLock?
    public init(id: String, name: String, av: String, lock: PinLock? = nil) { self.id = id; self.name = name; self.av = av; self.lock = lock }
    public var locked: Bool { lock != nil }
}

/// A profile's 4-digit PIN as the synced `viewers` doc keeps it: `lock {s, h}` — an 8-hex salt and `pinHash(s, pin)`.
/// A household lock, not security: 10 000 PINs can all be tried; the hash only keeps the PIN out of plain sight.
public struct PinLock: Equatable, Sendable {
    public let s: String
    public let h: String

    /// nil unless both are 8 lowercase hex digits (a profile is locked only then).
    public init?(s: String, h: String) {
        guard PinLock.hex8(s), PinLock.hex8(h) else { return nil }
        self.s = s; self.h = h
    }
    public init?(_ o: JSONObject?) {
        guard let o = o else { return nil }
        self.init(s: o.str("s"), h: o.str("h"))
    }
    /// A new lock for this PIN, with a fresh salt.
    public static func make(pin: String) -> PinLock? {
        guard pinOk(pin) else { return nil }
        let salt = PinLock.salt()
        return PinLock(s: salt, h: PinLock.pinHash(salt, pin))
    }
    public func matches(_ pin: String) -> Bool { PinLock.pinOk(pin) && PinLock.pinHash(s, pin) == h }
    public var json: JSONObject { ["s": s, "h": h] }

    public static func pinOk(_ pin: String) -> Bool { pin.count == 4 && pin.allSatisfy { $0 >= "0" && $0 <= "9" } }
    static func hex8(_ x: String) -> Bool { x.utf8.count == 8 && x.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) } }
    /// 8 lowercase hex digits.
    public static func salt() -> String { hex(UInt32.random(in: 0...UInt32.max)) }
    static func hex(_ v: UInt32) -> String {
        let x = String(v, radix: 16)
        return String(repeating: "0", count: 8 - x.count) + x
    }

    /// FNV-1a 32-bit over "salt:pin", 1000 rounds, the basis set once — identical to the shared player and Android.
    public static func pinHash(_ salt: String, _ pin: String) -> String {
        let bytes = Array((salt + ":" + pin).utf8)
        var h: UInt32 = 2166136261
        for _ in 0..<1000 {
            for c in bytes { h = (h ^ UInt32(c)) &* 16777619 }
        }
        return hex(h)
    }
}

public func pinHash(_ salt: String, _ pin: String) -> String { PinLock.pinHash(salt, pin) }

/// Who's watching (0.5.0; the shared player's `viewers`, the same wire). An account holds up to two profiles. Each keeps
/// its own watch history — Continue Watching, resume points, ticks, My List — and its own add-ons; settings stay the
/// account's. The first profile's IS the account's as it always was ("progress", "library", "addons"), so nothing moves
/// for anyone; the second's sits beside it ("progress_b", "library_b", "addons_b") on this device and in the cloud. The list is synced
/// (`viewers`: {at, list:[{id, name, av, lock?}]}, newest wins; `lock` = the PIN, PinLock); which profile this device is on is not.
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
            if (id == "a" || id == "b") && out[id] == nil { out[id] = Viewer(id: id, name: String(o.str("name").prefix(24)), av: o.str("av"), lock: PinLock(o.obj("lock"))) }
        }
        if out["a"] == nil { out["a"] = Viewer(id: "a", name: "", av: "") }
        return out.values.sorted { $0.id < $1.id }
    }

    /// A new list, stamped now (it goes up with `viewers`).
    public func setList(_ l: [Viewer]) {
        let arr: [Any] = l.map { v -> JSONObject in
            var o: JSONObject = ["id": v.id, "name": String(v.name.prefix(24)), "av": v.av]
            if let k = v.lock { o["lock"] = k.json }
            return o
        }
        store.setObject("viewers_v1", ["at": nowMs(), "list": arr])
    }

    /// The second profile's documents on this device (its history, My List, add-ons and their stamps, the
    /// provisional-copy mark) — gone when the device is signed in to another account (Cloud.adopt).
    public static let secondKeys = ["progress_b", "library_b", "addons_b", "addons_sync_b", AddonStore.seedFlag]

    /// Another account on this device: back on the first profile, and no list (stamped 0, so the account's wins).
    public func forgetAccount() {
        setCurrent("a")
        store.setObject("viewers_v1", ["at": 0, "list": [Any]()])
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
