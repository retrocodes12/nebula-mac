import Foundation

/// Device-local preferences. Nothing here syncs.
public final class Prefs: @unchecked Sendable {
    let store: Store
    public init(store: Store) { self.store = store }

    private func get(_ k: String) -> Any? { store.object("prefs")[k] }
    private func put(_ k: String, _ v: Any) {
        var o = store.object("prefs"); o[k] = v
        store.setObject("prefs", o)
    }

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
    /// Preferred caption language (ISO 639-2, as add-ons give it); empty = off until picked.
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
}
