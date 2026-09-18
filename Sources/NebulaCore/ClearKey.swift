import Foundation

/// Decryption keys for protected streams. They reach the player three ways, the same three the
/// shared player reads: a `#clearkey=kid:key,…` tail on the address, a `clearKeys` object on the
/// stream row, or a licence address written inside the manifest.
public enum ClearKey {
    static func hex(_ s: String) -> String {
        s.filter { $0.isHexDigit }.lowercased()
    }

    public static func cleanUrl(_ u: String) -> String {
        guard let r = u.range(of: "#clearkey=") else { return u }
        return String(u[..<r.lowerBound])
    }

    public static func fromFragment(_ u: String) -> [String: String] {
        guard let r = u.range(of: "#clearkey=") else { return [:] }
        let tail = String(u[r.upperBound...])
        var keys: [String: String] = [:]
        for pair in (tail.removingPercentEncoding ?? tail).split(separator: ",") {
            guard let i = pair.firstIndex(of: ":") else { continue }
            let k = hex(String(pair[..<i])), v = hex(String(pair[pair.index(after: i)...]))
            if k.count == 32 && v.count == 32 { keys[k] = v }
        }
        return keys
    }

    public static func extract(stream s: JSONObject) -> [String: String] {
        var keys = fromFragment(s.str("url"))
        let src = s.obj("clearKeys") ?? s.obj("keys") ?? s.obj("behaviorHints")?.obj("clearKeys") ?? [:]
        for (k, v) in src {
            guard let v = v as? String else { continue }
            let kk = hex(k), vv = hex(v)
            if kk.count == 32 && vv.count == 32 { keys[kk] = vv }
        }
        return keys
    }

    public static func base64urlToHex(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return "" }
        return d.map { String(format: "%02x", $0) }.joined()
    }

    /// The licence address a manifest names (dashif:laurl / clearkey:Laurl), if any.
    public static func licenceUrl(inManifest xml: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<(?:\\w+:)?laurl[^>]*>([^<]+)</(?:\\w+:)?laurl>", options: [.caseInsensitive]) else { return nil }
        let ns = xml as NSString
        guard let m = re.firstMatch(in: xml, options: [], range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Keys out of a licence reply: `{keys: [{kid, k}]}`, both base64url.
    public static func keys(fromLicence j: JSONObject) -> [String: String] {
        var keys: [String: String] = [:]
        for k in j.objs("keys") {
            let kid = base64urlToHex(k.str("kid")), key = base64urlToHex(k.str("k"))
            if kid.count == 32 && key.count == 32 { keys[kid] = key }
        }
        return keys
    }

    /// Read the manifest, follow its licence address, return the keys. Empty when it names none.
    public static func resolve(manifestUrl: String, using stremio: Stremio) async -> [String: String] {
        guard let data = try? await stremio.getData(manifestUrl), let xml = String(data: data, encoding: .utf8),
              let lic = licenceUrl(inManifest: xml), let j = try? await stremio.getJSON(lic) else { return [:] }
        return keys(fromLicence: j)
    }

    public static func looksLikeDash(_ url: String) -> Bool {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        return path.lowercased().hasSuffix(".mpd")
    }

    /// What the engine's demuxer is told: every key by id, plus the first one as the default for
    /// a file that does not say which id it used.
    public static func demuxerOptions(_ keys: [String: String]) -> String {
        guard !keys.isEmpty else { return "" }
        let sorted = keys.sorted { $0.key < $1.key }
        let byId = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: ":")
        return "cenc_decryption_key=\(sorted[0].value),cenc_decryption_keys=\(byId)"
    }
}
