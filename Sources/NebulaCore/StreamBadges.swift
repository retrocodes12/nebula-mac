import Foundation

/// Reads a stream row's free text: the resolution plate, the badge set, the facts (size, rate,
/// seeds, languages, provider) and whatever description is left once those are taken out.
public enum StreamBadges {
    struct Rule { let group: String; let re: NSRegularExpression; let file: String }

    static func rx(_ p: String) -> NSRegularExpression {
        // the patterns are literals in this file; a bad one is a programming error
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static func hit(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    static func strip(_ re: NSRegularExpression, _ s: String, with t: String = " ") -> String {
        re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    // First hit per group becomes a badge; within a group the table runs specific → generic.
    static let pack: [Rule] = [
        ("resolution", #"\b(4k|2160p|uhd|ultra\s*hd)\b"#, "4k_ultra_hd.png"),
        ("resolution", #"\b(1080p|fhd|full\s*hd)\b"#, "1080p_full_hd.png"),
        ("resolution", #"\b720p\b"#, "720p_hd.png"),
        ("resolution", #"\b480p\b"#, "480p_sd.png"),
        ("video-tech", #"\b(dolby\s*vision|dovi|dv)\b"#, "dolby_vision.png"),
        ("video-tech", #"\b(hdr10\+|hdr10\s*plus\b|hdr\s*10\s*\+)"#, "hdr10_plus.png"),
        ("video-tech", #"\b(hdr10|hdr\s*10)\b(?!\s*\+|\s*plus)"#, "hdr10.png"),
        ("video-tech", #"\bhdr\b"#, "hdr.png"),
        ("video-tech", #"\bsdr\b"#, "SDR_transparent_4x.png"),
        ("video-tech", #"\b(imax[\s._-]*enhanced)\b"#, "imax_enhanced.png"),
        ("video-tech", #"\b(imax)\b(?![\s._-]*enhanced)"#, "imax.png"),
        ("source", #"\bremux\b"#, "remux.png"),
        ("source", #"\b(blu[\s._-]?ray|bluray|bdrip|bdremux)\b"#, "blu_ray_disc.png"),
        ("source", #"\b(web[\s._-]?dl|webdl)\b"#, "WEBDL_transparent_4x.png"),
        ("source", #"\b(web[\s._-]?rip|webrip)\b"#, "WEBRip_transparent_4x.png"),
        ("source", #"\bhdtv\b"#, "HDTV_transparent_4x.png"),
        ("source", #"\b(dvd[\s._-]?rip|dvdrip)\b"#, "DVD_RIP_transparent_4x.png"),
        ("video-codec", #"\b(hevc|h[\s._-]?265|x265)\b"#, "HEVC_transparent_4x.png"),
        ("video-codec", #"\b(avc|h[\s._-]?264|x264)\b"#, "AVC_transparent_4x.png"),
        ("bit-depth", #"\b(10[\s._-]?bit|10b|hi10p)\b"#, "10Bit_transparent_4x.png"),
        ("bit-depth", #"\b(8[\s._-]?bit|8b)\b"#, "8Bit_transparent_4x.png"),
        ("audio-tech", #"\b(dolby\s*atmos|atmos)\b"#, "dolby_atmos.png"),
        ("audio-tech", #"\b(truehd|true\s*hd|dolby\s*truehd)\b"#, "truehd.png"),
        ("audio-tech", #"\b(ddp[\s._-]*[0-9][\s._-]*[0-9]|ddp|dd\+|dolby[\s._-]*digital[\s._-]*plus|e-?ac-?3)(?![a-z])"#, "dolby_digital_plus.png"),
        ("audio-tech", #"\b(dd[\s._-]*[0-9][\s._-]*[0-9]|dd|dolby[\s._-]*digital|ac-?3)(?![\s._-]*plus|\+|p|[a-z])"#, "dolby_digital.png"),
        ("audio-tech", #"\b(dts[:\s._-]*x)\b"#, "dts_x.png"),
        ("audio-tech", #"\b(dts[\s._-]*hd[\s._-]*ma|dtshd\s*ma|dts[\s._-]*hd[\s._-]*master)\b"#, "dts_hd_master_audio.png"),
        ("audio-tech", #"\b(dts[\s._-]*hd|dtshd)(?![\s._-]*(ma|master)|ma)\b"#, "dts_hd.png"),
        ("audio-tech", #"\bdts\b(?![\s._:-]*(x|hd))"#, "dts.png"),
        ("audio-channels", #"\b(7\.1|7-1|8ch|8\s*channel)\b"#, "7_1_audio.png"),
        ("audio-channels", #"\b(5\.1|5-1|6ch|6\s*channel)\b"#, "5_1_audio.png"),
    ].map { Rule(group: $0.0, re: rx($0.1), file: $0.2) }

    public struct Match {
        public var badges: [String]
        var fired: [NSRegularExpression]
    }

    /// Badge file names for a row. `skipGroup` is a group shown elsewhere (the resolution plate).
    public static func match(_ raw: String, skipGroup: String? = "resolution") -> Match {
        var seen = Set<String>()
        var badges: [String] = []
        var fired: [NSRegularExpression] = []
        for r in pack where hit(r.re, raw) {
            fired.append(r.re)                        // every match cleans the text line
            if r.group == skipGroup || seen.contains(r.group) || badges.count >= 6 { continue }
            seen.insert(r.group)
            badges.append(r.file)
        }
        return Match(badges: badges, fired: fired)
    }

    public struct Plate: Equatable, Sendable { public var res: String; public var tag: String }

    static let re4k = rx(#"\b(4k|2160p|uhd)\b"#), re1080 = rx(#"\b(1080p|fhd)\b"#)
    static let re720 = rx(#"\b720p\b"#), reSd = rx(#"\b(480p|360p)\b"#)

    /// The resolution leads the row as a plate — it is what you choose by.
    public static func plate(_ raw: String) -> Plate? {
        if hit(re4k, raw) { return Plate(res: "4K", tag: "ULTRA HD") }
        if hit(re1080, raw) { return Plate(res: "1080", tag: "FULL HD") }
        if hit(re720, raw) { return Plate(res: "720", tag: "HD") }
        if hit(reSd, raw) { return Plate(res: "SD", tag: "") }
        return nil
    }

    public static func resRank(_ raw: String) -> Int {
        switch plate(raw)?.res { case "4K": return 4; case "1080": return 3; case "720": return 2; case "SD": return 1; default: return 0 }
    }

    static let reEmoji = rx(#"[\x{2190}-\x{21FF}\x{2300}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}\x{200D}]|[\x{1F000}-\x{1FAFF}]"#)
    static let reRes = rx(#"\b(4k|2160p|uhd|1080p|fhd|720p|480p|360p)\b"#)
    static let reSeps = rx(#"\s*[·•|]\s*"#), reSpaces = rx(#"\s{2,}"#)
    static let reSize = rx(#"(\d+(?:[.,]\d+)?)\s*(GB|GiB|MB|MiB)\b"#)
    static let reBitrate = rx(#"~?\s*(\d+(?:\.\d+)?)\s*Mbps\b"#)
    static let reSeedsEmoji = rx(#"\x{1F464}\s*(\d+)"#), reSeedsText = rx(#"\b(?:seeds?|seeders?)[:\s]+(\d+)"#)
    static let reSource = rx(#"\bsource\s*:?\s+(.+)"#)
    static let reBullet = rx(#"\s*[\x{00b7}\x{2022}]\s*"#)
    static let langs = ["English", "French", "Italian", "Spanish", "German", "Hindi", "Tamil", "Telugu", "Malayalam", "Kannada",
                        "Polish", "Portuguese", "Russian", "Japanese", "Korean", "Chinese", "Arabic", "Turkish", "Dutch", "Latino", "Multi"]
    static let reLang = rx(#"\b("# + langs.joined(separator: "|") + #"|Dual\s*Audio)\b"#)
    static let reFlag = rx(#"[\x{1F1E6}-\x{1F1FF}]"#)
    static let reJoiners = rx(#"[+,&/\s]|and"#)
    static let flagLangs: [(String, String)] = [
        ("🇬🇧", "English"), ("🇺🇸", "English"), ("🇫🇷", "French"), ("🇮🇹", "Italian"), ("🇪🇸", "Spanish"), ("🇩🇪", "German"),
        ("🇮🇳", "Hindi"), ("🇵🇱", "Polish"), ("🇧🇷", "Portuguese"), ("🇷🇺", "Russian"), ("🇯🇵", "Japanese"), ("🇰🇷", "Korean"),
    ]

    /// The row sits under its add-on's heading and beside its own plate, so the name only has to
    /// say which RELEASE this is.
    public static func cleanName(_ raw: String, addonName: String?) -> String {
        var t = strip(reEmoji, raw.replacingOccurrences(of: "\n", with: " "))
        if let a = addonName, !a.trimmingCharacters(in: .whitespaces).isEmpty {
            t = strip(rx("\\b" + NSRegularExpression.escapedPattern(for: a) + "\\b"), t)
        }
        t = strip(reRes, t)
        t = strip(reSeps, t, with: " · ")
        t = strip(reSpaces, t)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "·•|,- "))
    }

    public struct Facts: Equatable, Sendable {
        public var line: String
        public var desc: String
        public var size: String?
        public var bitrate: String?
        public var seeds: String?
        public var langs: String
        public var provider: String?
    }

    static func fmtBytes(_ n: Int64) -> String {
        let g = Double(n) / 1_073_741_824
        if g >= 10 { return "\(Int(g.rounded())) GB" }
        if g >= 1 { return String(format: "%.1f GB", g) }
        return "\(Int((Double(n) / 1_048_576).rounded())) MB"
    }

    static func langsIn(_ raw: String) -> String {
        var out: [String] = []
        let ns = raw as NSString
        for m in reLang.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) where out.count < 4 {
            var n = ns.substring(with: m.range(at: 1)).split(whereSeparator: { $0 == " " }).joined(separator: " ").lowercased()
            n = n.prefix(1).uppercased() + n.dropFirst()
            if n == "Dual audio" { n = "Dual Audio" }
            if !out.contains(n) { out.append(n) }
        }
        for (f, n) in flagLangs where out.count < 4 && raw.contains(f) && !out.contains(n) { out.append(n) }
        if out.isEmpty { return "" }
        return out.prefix(3).joined(separator: " + ") + (out.count > 3 ? " +\(out.count - 3)" : "")
    }

    /// Size, rate, seeders and provider pulled out of the stream text; lines that only carried
    /// those are consumed, bullet tokens the badges already show are dropped, the rest is the desc.
    public static func facts(videoSize: Int64, text: String, fired: [NSRegularExpression] = []) -> Facts {
        var size: String? = videoSize > 0 ? fmtBytes(videoSize) : nil
        var seeds: String?, provider: String?, bitrate: String?
        var desc: [String] = []
        // "⚙️" is a gear plus a variation selector, which Swift reads as ONE character that is not
        // equal to a bare gear — drop the selectors so the markers can be found at all
        let text = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0F }))
        for ln in text.components(separatedBy: "\n") {
            let factLine = ln.contains("👤") || ln.contains("💾") || ln.contains("⚙")
            if size == nil, let g = groups(reSize, ln) {
                let u = g[2]
                size = g[1].replacingOccurrences(of: ",", with: ".") + " " + (u.count == 3 ? u.prefix(1).uppercased() + "iB" : u.uppercased())
            }
            if bitrate == nil, let g = groups(reBitrate, ln) { bitrate = g[1] + " Mbps" }
            if seeds == nil, let g = groups(reSeedsEmoji, ln) ?? groups(reSeedsText, ln) { seeds = g[1] }
            if provider == nil, let ix = ln.range(of: "⚙") {
                var pv = String(ln[ix.upperBound...])
                for stop in ["👤", "💾"] { if let r = pv.range(of: stop) { pv = String(pv[..<r.lowerBound]) } }
                pv = pv.trimmingCharacters(in: .whitespaces)
                if !pv.isEmpty { provider = pv }
            }
            if factLine || ln.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if ln.contains("·") || ln.contains("•") {
                var kept: [String] = []
                for tok in strip(reBullet, ln, with: "\u{1}").components(separatedBy: "\u{1}") where !tok.isEmpty {
                    if let g = groups(reSource, tok) { if provider == nil { provider = g[1].trimmingCharacters(in: .whitespaces) }; continue }
                    if hit(reBitrate, tok) || hit(reSize, tok) { continue }
                    if strip(reJoiners, strip(reFlag, strip(reLang, tok, with: ""), with: ""), with: "").isEmpty { continue }
                    if fired.contains(where: { hit($0, tok) }) { continue }
                    kept.append(tok)
                }
                if !kept.isEmpty { desc.append(kept.joined(separator: " · ")) }
            } else {
                desc.append(ln.trimmingCharacters(in: .whitespaces))
            }
        }
        let langs = langsIn(text)
        var line: [String] = []
        if let s = size { line.append(s) }
        if let b = bitrate { line.append(b) }
        if let s = seeds { line.append(s + " seeds") }
        if !langs.isEmpty { line.append(langs) }
        if let p = provider { line.append(p) }
        return Facts(line: line.joined(separator: "  ·  "), desc: desc.joined(separator: " · "),
                     size: size, bitrate: bitrate, seeds: seeds, langs: langs, provider: provider)
    }
}
