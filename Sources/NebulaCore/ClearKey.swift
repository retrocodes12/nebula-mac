import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

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

    /// Only a ClearKey protection element may name our licence, not a neighbouring DRM scheme.
    public static func licenceUrl(inManifest xml: String) -> String? {
        let reader = LicenceReader(), parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        _ = parser.parse()
        if let licence = reader.licence { return licence }
        return licenceFallback(inManifest: xml)
    }

    private static func isClearKey(_ scheme: String) -> Bool {
        switch scheme.lowercased() {
        case "urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e", "urn:uuid:1077efec-c0b2-4d02-ace3-3c1e52e2fb4b", "urn:mpeg:dash:clearkey:2013": return true
        default: return false
        }
    }

    /// Some hosts omit the namespace declaration. Read only within a ClearKey protection block.
    static func licenceFallback(inManifest xml: String) -> String? {
        let comments = DashManifest.rx(#"<!--.*?-->"#)
        let clean = comments.stringByReplacingMatches(in: xml, range: NSRange(xml.startIndex..., in: xml), withTemplate: "")
        let protection = DashManifest.rx(#"<(?:[\w.-]+:)?ContentProtection\b[^>]*?(?:/>|>.*?</(?:[\w.-]+:)?ContentProtection\s*>)"#)
        let laurl = DashManifest.rx(#"<(?:[\w.-]+:)?laurl\b[^>]*>(\s*<!\[CDATA\[.*?\]\]>\s*|[^<]*)</(?:[\w.-]+:)?laurl\s*>"#)
        for block in DashManifest.matches(protection, clean) {
            guard isClearKey(DashManifest.attr("schemeIdUri", in: DashManifest.openTag(block)) ?? "") else { continue }
            for match in laurl.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
                guard let range = Range(match.range(at: 1), in: block) else { continue }
                let raw = block[range].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = raw.hasPrefix("<![CDATA[") ? String(raw.dropFirst(9).dropLast(3)) : DashManifest.xmlDecoded(raw)
                let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty { return address }
            }
        }
        return nil
    }

    private final class LicenceReader: NSObject, XMLParserDelegate {
        var schemes: [String] = []
        var licence: String?
        var text: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            if elementName.lowercased() == "contentprotection" { schemes.append((attributes["schemeIdUri"] ?? "").lowercased()) }
            guard elementName.lowercased() == "laurl", let scheme = schemes.last, licence == nil else { return }
            let clear = ClearKey.isClearKey(scheme)
            let clearNamespace = namespaceURI?.lowercased() == "http://dashif.org/guidelines/clearkey"
            if clear || (scheme.isEmpty && clearNamespace) { text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if text != nil { text! += string } }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if text != nil, let value = String(data: CDATABlock, encoding: .utf8) { text! += value }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName.lowercased() == "laurl", let value = text {
                let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty { licence = address }
                text = nil
            }
            if elementName.lowercased() == "contentprotection" { _ = schemes.popLast() }
        }
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

    /// Read the manifest, retaining its final address after redirects for a relative licence.
    public static func resolve(manifestUrl: String, headers: [String: String] = [:], using stremio: Stremio) async -> [String: String] {
        guard !Task.isCancelled, let url = URL(string: manifestUrl), Stremio.isWeb(manifestUrl) else { return [:] }
        var request = Net.addonRequest(url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, code, finalURL) = try? await stremio.transport.sendWithURL(request), (200...299).contains(code),
              !Task.isCancelled, let xml = String(data: data, encoding: .utf8) else { return [:] }
        return await resolve(xml: xml, manifestUrl: finalURL.absoluteString, headers: headers, headerOrigin: manifestUrl, using: stremio)
    }

    /// `manifestUrl` is the final fetched address; send headers on the licence request only
    /// when it shares `headerOrigin` (by default the manifest's origin).
    public static func resolve(xml: String, manifestUrl: String, headers: [String: String] = [:],
                               headerOrigin: String? = nil, using stremio: Stremio) async -> [String: String] {
        guard !Task.isCancelled, let base = URL(string: manifestUrl), let lic = licenceUrl(inManifest: xml),
              let url = URL(string: lic, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return [:] }
        let origin = URL(string: headerOrigin ?? manifestUrl)
        let scoped = origin.map { Net.sameOrigin($0, url) } == true ? headers : [:]
        guard let j = try? await stremio.getJSON(url.absoluteString, headers: scoped), !Task.isCancelled else { return [:] }
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
