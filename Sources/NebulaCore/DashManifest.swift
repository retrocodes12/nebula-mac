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
        guard let re = try? NSRegularExpression(pattern: "\\b" + name + "=\"([^\"]*)\"", options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, options: [], range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
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
            let fitting = maxHeight > 0 ? reps.filter { height($0) > 0 && height($0) <= maxHeight } : reps
            let keep: String
            if let best = fitting.max(by: { (height($0), bandwidth($0)) < (height($1), bandwidth($1)) }) { keep = best }
            else { keep = reps.min(by: { (height($0), bandwidth($0)) < (height($1), bandwidth($1)) })! }
            var trimmed = set
            for r in reps where r != keep { trimmed = trimmed.replacingOccurrences(of: r, with: "") }
            out = out.replacingOccurrences(of: set, with: trimmed)
        }
        return out
    }

    /// Served from another address, a manifest's relative addresses would point at the wrong
    /// host: give it an absolute base — its own folder — unless it already names one.
    public static func absoluteBase(_ xml: String, manifestUrl: String) -> String {
        guard let here = URL(string: manifestUrl) else { return xml }
        let folder = here.deletingLastPathComponent()
        var folderText = folder.absoluteString
        if let q = folderText.firstIndex(of: "?") { folderText = String(folderText[..<q]) }
        let periodAt = xml.range(of: "<Period", options: [.caseInsensitive])?.lowerBound ?? xml.endIndex
        let top = String(xml[..<periodAt])
        if let m = reBase.firstMatch(in: top, options: [], range: NSRange(top.startIndex..., in: top)),
           let whole = Range(m.range, in: top), let inner = Range(m.range(at: 1), in: top) {
            let value = top[inner].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") { return xml }
            guard let resolved = URL(string: value, relativeTo: folder)?.absoluteString else { return xml }
            let fixed = String(top[whole]).replacingOccurrences(of: String(top[inner]), with: resolved)
            return xml.replacingOccurrences(of: String(top[whole]), with: fixed, options: [], range: xml.startIndex..<periodAt)
        }
        guard let m = reMpdOpen.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)), let r = Range(m.range, in: xml) else { return xml }
        var s = xml
        s.insert(contentsOf: "<BaseURL>\(folderText)</BaseURL>", at: r.upperBound)
        return s
    }
}
