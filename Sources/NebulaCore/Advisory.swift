import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The content advisory a film or episode shows for a few seconds as it first plays ("Violence · Severe") and the
/// title's age rating where this device is ("UA", "PG-13", "TV-MA") — one answer from Nebula Cloud,
/// `/v1/advisory?id=tt…&cc=IN`, kept two weeks there and for this run here. The request carries the title id and a
/// two-letter country, nothing else. The shared player's `advFetch` / `ageRegion`, Android's `Advisory.kt`.
public enum Advisory {
    public struct Warn: Equatable, Sendable {
        public var kind: String
        public var level: String
        public init(kind: String, level: String) { self.kind = kind; self.level = level }
    }

    public struct Answer: Equatable, Sendable {
        public var warns: [Warn]
        public var cert: String
        public init(warns: [Warn], cert: String) { self.warns = warns; self.cert = cert }
        /// The overlay's rows: "Rated · UA" first, then the levels.
        public var rows: [Warn] { (cert.isEmpty ? [] : [Warn(kind: "Rated", level: cert)]) + warns }
    }

    static let kinds = ["violence": "Violence", "profanity": "Profanity", "frightening": "Frightening",
                        "nudity": "Nudity", "alcohol": "Alcohol/Drugs"]
    static let levels = ["severe": "Severe", "moderate": "Moderate", "mild": "Mild"]

    /// The title's own tt… id (an episode id gives its show's), or nil when it has none.
    public static func idOf(_ id: String) -> String? { Universe.idOf(id) }

    public static func parse(_ o: JSONObject) -> Answer {
        var warns: [Warn] = []
        for x in o.objs("items") {
            guard let k = kinds[x.str("k")], let s = levels[x.str("s")] else { continue }
            warns.append(Warn(kind: k, level: s))
        }
        let cert = o.str("cert").trimmingCharacters(in: .whitespaces)
        return Answer(warns: Array(warns.prefix(5)), cert: cert.count <= 16 ? cert : "")
    }

    // The country whose rating is shown: the clock's time zone first (a TV or a phone set to American English is
    // still where its clock says), then the locale's region, else the US.
    static let zones: [String: String] = [
        "Asia/Kolkata": "IN", "Asia/Calcutta": "IN", "Europe/London": "GB", "Europe/Dublin": "IE", "Europe/Berlin": "DE",
        "Europe/Paris": "FR", "Europe/Madrid": "ES", "Europe/Rome": "IT", "Europe/Amsterdam": "NL", "Europe/Brussels": "BE",
        "Europe/Zurich": "CH", "Europe/Vienna": "AT", "Europe/Stockholm": "SE", "Europe/Oslo": "NO", "Europe/Copenhagen": "DK",
        "Europe/Helsinki": "FI", "Europe/Lisbon": "PT", "Europe/Warsaw": "PL", "Europe/Istanbul": "TR", "Asia/Dubai": "AE",
        "Asia/Riyadh": "SA", "Asia/Singapore": "SG", "Asia/Kuala_Lumpur": "MY", "Asia/Manila": "PH", "Asia/Jakarta": "ID",
        "Asia/Tokyo": "JP", "Asia/Seoul": "KR", "Asia/Karachi": "PK", "Asia/Dhaka": "BD", "Asia/Colombo": "LK",
        "Asia/Kathmandu": "NP", "Africa/Johannesburg": "ZA", "Africa/Lagos": "NG", "Africa/Nairobi": "KE",
        "America/Sao_Paulo": "BR", "America/Mexico_City": "MX", "America/Argentina/Buenos_Aires": "AR",
        "America/Toronto": "CA", "America/Vancouver": "CA", "Pacific/Auckland": "NZ",
    ]
    static let usZones = ["America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "America/Phoenix",
                          "America/Anchorage", "America/Detroit", "America/Boise", "America/Indiana", "America/Kentucky", "Pacific/Honolulu"]

    public static func region(timeZone tz: String, locale: String) -> String {
        var cc = zones[tz] ?? ""
        if cc.isEmpty && tz.hasPrefix("Australia/") { cc = "AU" }
        if cc.isEmpty && usZones.contains(where: { tz.hasPrefix($0) }) { cc = "US" }
        if cc.isEmpty {
            // "en_IN", "en-GB", "fr_FR@calendar=…": the two capitals after the separator
            let parts = locale.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "@" })
            if parts.count >= 2, parts[1].count == 2 { cc = parts[1].uppercased() }
        }
        return cc.count == 2 && cc.allSatisfy({ $0.isLetter && $0.isASCII }) ? cc : "US"
    }

    public static let deviceRegion: String = region(timeZone: TimeZone.current.identifier, locale: Locale.current.identifier)

    private static let cache = Cache<Answer>()

    public static func cached(_ tt: String) -> Answer? { cache.get(tt) }

    /// nil when the cloud could not be reached — asked again the next time.
    public static func load(_ tt: String, base: String = Cloud.defaultBase, transport: Transport = URLSessionTransport(timeout: 10)) async -> Answer? {
        if let c = cache.get(tt) { return c }
        var comps = URLComponents(string: base + "/v1/advisory")
        comps?.queryItems = [URLQueryItem(name: "id", value: tt), URLQueryItem(name: "cc", value: deviceRegion)]
        guard let url = comps?.url else { return nil }
        var r = URLRequest(url: url)
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, code) = try? await transport.send(r), (200...299).contains(code), let o = JSON.object(data) else { return nil }
        let a = parse(o)
        cache.put(tt, a)
        return a
    }
}
