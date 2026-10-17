import Foundation

/// A release's file name with the episode taken out: "Show.S01E03.Pilot.1080p.WEB.x265-GRP" and
/// "Show.S01E04.Other.Name.1080p.WEB.x265-GRP" give the same key — the show part before the episode
/// plus the release tail from its first quality word (episode names differ, so they never count).
/// A film keeps its whole name. "" when the row names no file. Mirrors the web player's releaseKey.
public enum ReleaseKey {
    private static let ext = try! NSRegularExpression(pattern: "\\.(mkv|mp4|m4v|avi|webm|mov|ts|wmv|flv)$")
    private static let episode = try! NSRegularExpression(pattern:
        "(^|[^a-z0-9])(s\\d{1,2}[ ._-]?e\\d{1,3}(?:[-e]+\\d{1,3})?|\\d{1,2}x\\d{2,3}|(?:ep|episode)[ ._-]?\\d{1,3})(?=[^a-z0-9]|$)")
    private static let quality: Set<String> = ["2160p", "1080p", "720p", "576p", "480p", "4k", "uhd", "web", "webrip", "webdl",
        "bluray", "bdrip", "brrip", "hdtv", "dvdrip", "remux", "hdr", "hdr10", "dv", "x264", "x265", "h264", "h265", "hevc",
        "avc", "av1", "10bit", "amzn", "nf", "dsnp", "hmax", "atvp"]

    private static func tokens(_ t: Substring) -> [String] {
        t.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
    }

    public static func of(_ name: String) -> String {
        var n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let slash = n.lastIndex(where: { $0 == "/" || $0 == "\\" }) { n = String(n[n.index(after: slash)...]) }
        n = ext.stringByReplacingMatches(in: n, range: NSRange(n.startIndex..., in: n), withTemplate: "")
        if n.isEmpty { return "" }
        guard let m = episode.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
              let lead = Range(m.range(at: 1), in: n), let ep = Range(m.range(at: 2), in: n) else {
            let all = tokens(n[...])
            return all.count >= 3 ? "m:" + all.joined(separator: ".") : ""
        }
        let head = tokens(n[..<lead.upperBound])
        var tail = tokens(n[ep.upperBound...])
        if let q = tail.firstIndex(where: { quality.contains($0) }) { tail = Array(tail[q...]) }
        else { tail = Array(tail.suffix(1)) }                       // no quality word: the release group alone
        if head.isEmpty || tail.isEmpty { return "" }
        return "e:" + head.joined(separator: ".") + "|" + tail.joined(separator: ".")
    }

    /// The file a row plays, by name: the add-on's own filename hint, else a title line that reads like one.
    public static func fileName(_ s: StreamItem) -> String {
        if !s.fileName.isEmpty { return s.fileName }
        for raw in s.title.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if ext.firstMatch(in: l.lowercased(), range: NSRange(location: 0, length: l.lowercased().utf16.count)) != nil { return l }
            if !l.contains(" ") && l.split(separator: ".").count >= 4 { return l }
        }
        return ""
    }

    /// The key of the release a row plays.
    public static func of(_ s: StreamItem) -> String { of(fileName(s)) }
}
