import Foundation

/// Device-local preferences. Nothing here syncs — except the two documents at the end, which
/// ride on the profile (the caller tells the cloud they changed).
public final class Prefs: @unchecked Sendable {
    let store: Store
    /// The document, parsed once. Every read used to parse the whole file again, and the player
    /// reads several of these each time it draws; only this object writes the file.
    private var cache: JSONObject?
    private let lock = NSLock()

    public init(store: Store) { self.store = store }

    private func get(_ k: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        if cache == nil { cache = store.object("prefs") }
        return cache?[k]
    }

    private func put(_ k: String, _ v: Any) {
        lock.lock(); defer { lock.unlock() }
        var o = cache ?? store.object("prefs"); o[k] = v
        cache = o
        store.setObject("prefs", o)
    }

    /// Gold, Ice and Mint — for supporters (the shared player's SUP_ACCENTS).
    public static let supporterAccents: [(name: String, hex: String)] = [("Gold", "#E0B24A"), ("Ice", "#64D2FF"), ("Mint", "#66D4CF")]

    public static let accents: [(name: String, hex: String)] = [
        ("Nebula Red", "#E50914"), ("White", "#F2F2F7"), ("Cobalt", "#0A84FF"), ("Emerald", "#30D158"),
        ("Violet", "#BF5AF2"), ("Amber", "#FF9F0A"), ("Rose", "#FF375F"),
    ]

    public var accent: String {
        get { (get("accent") as? String) ?? "#E50914" }
        set { put("accent", newValue) }
    }
    /// Seconds a left/right arrow moves.
    public var seekStep: Int {
        get { (get("seekStep") as? NSNumber)?.intValue ?? 10 }
        set { put("seekStep", newValue) }
    }
    public var resume: Bool {
        get { (get("resume") as? Bool) ?? true }
        set { put("resume", newValue) }
    }
    /// Offer the next episode as the credits approach.
    public var autoplayNext: Bool {
        get { (get("autoplayNext") as? Bool) ?? true }
        set { put("autoplayNext", newValue) }
    }
    /// An unset caption preference leaves the engine's choice alone; a stored empty one is Off.
    public var hasSubLang: Bool { self.get("subLang") is String }
    /// Preferred caption language, as add-ons give it.
    public var subLang: String {
        get { (get("subLang") as? String) ?? "" }
        set { put("subLang", newValue) }
    }
    public var audioLang: String {
        get { (get("audioLang") as? String) ?? "" }
        set { put("audioLang", newValue) }
    }
    public var volume: Double {
        get { (get("volume") as? NSNumber)?.doubleValue ?? 100 }
        set { put("volume", newValue) }
    }
    /// Let the engine decode on the GPU. Off is the fallback for a file that shows garbage.
    public var hardwareDecoding: Bool {
        get { (get("hwdec") as? Bool) ?? true }
        set { put("hwdec", newValue) }
    }
    /// The tallest picture a stream with several qualities is played at; 0 = the best it has.
    public var maxHeight: Int {
        get { (get("maxHeight") as? NSNumber)?.intValue ?? 0 }
        set { put("maxHeight", newValue) }
    }
    public var recentSearches: [String] {
        get { (get("recent_q") as? [String]) ?? [] }
        set { put("recent_q", Array(newValue.prefix(10))) }
    }
    public var discover: JSONObject {
        get { (get("discover") as? JSONObject) ?? [:] }
        set { put("discover", newValue) }
    }
    /// Skip intros and recaps: "button" (offer it), "auto" (skip by itself) or "off".
    public var skipIntro: String {
        get { let v = (get("skip") as? String) ?? "button"; return SkipSegments.modes.contains(v) ? v : "button" }
        set { put("skip", newValue) }
    }

    // MARK: synced documents (stored beside the prefs, merged by Cloud)

    /// The subtitle look, every key present. `subStyleChosen` false = never chosen anywhere: the
    /// engine keeps its own look.
    public var subStyle: [String: String] { SubStyle.normalize(store.object("sub_style").obj("style")) }
    public var subStyleChosen: Bool { store.object("sub_style").int64("at") > 0 }
    public func setSubStyle(_ s: [String: String]?) {
        store.setObject("sub_style", ["style": SubStyle.normalize(s ?? SubStyle.defaults), "at": nowMs()])
    }

    /// The viewer's own seekr.tv key ("" = none).
    public var seekrKey: String {
        let k = store.object("seekr_v1").str("key")
        return Seekr.validKey(k) ? k : ""
    }
    public func setSeekrKey(_ k: String) { store.setObject("seekr_v1", ["key": k, "at": nowMs()]) }
}
