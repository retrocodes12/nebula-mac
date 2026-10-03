import Foundation

/// Gets a DASH manifest ready for the engine. FFmpeg's DASH reader opens EVERY representation
/// before it shows a frame, and re-reads the manifest for each one — measured on a live sports
/// card: 8 manifest reads, ~2 s each from the add-on, 45 s to the first frame. The app therefore
/// serves the manifest from its own loopback cache, and hands over one video quality rather
/// than seven (the reader never switches quality by itself, so nothing is lost).
public enum DashManifest {
    static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    static let reSet = rx(#"<AdaptationSet\b.*?</AdaptationSet>"#)
    static let reRep = rx(#"<Representation\b[^>]*?(?:/>|>.*?</Representation>)"#)
    static let reBase = rx(#"<BaseURL[^>]*>([^<]*)</BaseURL>"#)
    static let reMpdOpen = rx(#"<MPD\b[^>]*>"#)

    static func attr(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, options: [], range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: m.range(at: 1).location == NSNotFound ? 2 : 1), in: tag) else { return nil }
        return xmlDecoded(String(tag[r]))
    }

    static func openTag(_ element: String) -> String {
        element.firstIndex(of: ">").map { String(element[...$0]) } ?? element
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> [String] {
        re.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// - maxHeight: the tallest picture wanted; 0 = the best there is.
    public static func prepare(_ xml: String, manifestUrl: String, maxHeight: Int = 0) -> String {
        absoluteBase(oneVideoQuality(xml, maxHeight: maxHeight), manifestUrl: manifestUrl)
    }

    /// Keep one representation in every video adaptation set: the best one no taller than asked,
    /// or the smallest when all of them are taller.
    public static func oneVideoQuality(_ xml: String, maxHeight: Int = 0) -> String {
        var out = xml
        for set in matches(reSet, xml) {
            let reps = matches(reRep, set)
            guard reps.count > 1 else { continue }
            let head = openTag(set).lowercased()
            let isVideo = head.contains("video") || reps.contains { r in
                let t = openTag(r).lowercased()
                return t.contains("video") || attr("height", in: t) != nil
            }
            guard isVideo else { continue }
            func bandwidth(_ r: String) -> Int { Int(attr("bandwidth", in: openTag(r)) ?? "") ?? 0 }
            func height(_ r: String) -> Int { Int(attr("height", in: openTag(r)) ?? attr("height", in: openTag(set)) ?? "") ?? 0 }
            let ranked = maxHeight > 0 ? reps.filter { height($0) > 0 } : reps
            guard ranked.contains(where: { height($0) > 0 || bandwidth($0) > 0 }) else { continue }
            let fitting = maxHeight > 0 ? ranked.filter { height($0) <= maxHeight } : ranked
            let keep: String
            if let best = fitting.max(by: { (height($0), bandwidth($0)) < (height($1), bandwidth($1)) }) { keep = best }
            else { keep = ranked.min(by: { (height($0), bandwidth($0)) < (height($1), bandwidth($1)) })! }
            var trimmed = set
            for r in reps where r != keep { trimmed = trimmed.replacingOccurrences(of: r, with: "") }
            out = out.replacingOccurrences(of: set, with: trimmed)
        }
        return out
    }

    static func xmlDecoded(_ text: String) -> String {
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
        let re = rx(#"&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos);"#)
        var out = text
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out), let inner = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[inner])
            var value = entities[name]
            if name.hasPrefix("#") {
                let hex = name.lowercased().hasPrefix("#x")
                if let n = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(n) { value = String(scalar) }
            }
            if let value = value { out.replaceSubrange(whole, with: value) }
        }
        return out
    }

    static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Served from another address, a manifest's relative addresses would point at the wrong
    /// host: give it an absolute base — its own folder — unless it already names one.
    public static func absoluteBase(_ xml: String, manifestUrl: String) -> String {
        guard let here = URL(string: manifestUrl) else { return xml }
        guard var folder = URLComponents(url: here.deletingLastPathComponent(), resolvingAgainstBaseURL: true) else { return xml }
        folder.query = nil; folder.fragment = nil
        guard let folderText = folder.url?.absoluteString else { return xml }
        let periodAt = xml.range(of: "<Period", options: [.caseInsensitive])?.lowerBound ?? xml.endIndex
        let top = String(xml[..<periodAt])
        if let m = reBase.firstMatch(in: top, options: [], range: NSRange(top.startIndex..., in: top)),
           let inner = Range(m.range(at: 1), in: top) {
            let value = xmlDecoded(top[inner].trimmingCharacters(in: .whitespacesAndNewlines))
            if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") { return xml }
            guard let resolved = URL(string: value, relativeTo: here)?.absoluteURL.absoluteString else { return xml }
            var fixed = xml
            guard let content = Range(m.range(at: 1), in: fixed) else { return xml }
            fixed.replaceSubrange(content, with: xmlEscaped(resolved))
            return fixed
        }
        guard let m = reMpdOpen.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)), let r = Range(m.range, in: xml) else { return xml }
        var s = xml
        s.insert(contentsOf: "<BaseURL>\(xmlEscaped(folderText))</BaseURL>", at: r.upperBound)
        return s
    }
}
