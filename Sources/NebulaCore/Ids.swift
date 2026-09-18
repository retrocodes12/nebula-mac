import Foundation

public enum Ids {
    /// The series behind an episode id. "tt123:1:2" → tt123 and "12345:1:2" → 12345; a prefixed id
    /// keeps its first two segments ("kitsu:12345:3" → kitsu:12345). A bare series id returns itself.
    public static func seriesId(of episodeId: String) -> String {
        let segs = episodeId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if segs.count < 2 { return episodeId }
        let first = segs[0].lowercased()
        let digits = first.hasPrefix("tt") ? String(first.dropFirst(2)) : first
        if !digits.isEmpty && digits.allSatisfy({ $0.isNumber }) { return segs[0] }
        return segs.prefix(2).joined(separator: ":")
    }

    /// (season, episode) off an episode id's tail; season is nil for an id that carries none.
    public static func episodeNumbers(of episodeId: String) -> (season: String?, episode: String)? {
        let root = seriesId(of: episodeId)
        if root == episodeId { return nil }
        let tail = String(episodeId.dropFirst(root.count + 1)).split(separator: ":").map(String.init)
        if tail.count >= 2 { return (tail[tail.count - 2], tail[tail.count - 1]) }
        if let one = tail.first, !one.isEmpty { return (nil, one) }
        return nil
    }

    /// "Season 1 · Episode 2", or "Episode 3" when the id has no season.
    public static func episodeKicker(_ episodeId: String) -> String? {
        guard let n = episodeNumbers(of: episodeId) else { return nil }
        if let s = n.season { return "Season \(s) · Episode \(n.episode)" }
        return "Episode \(n.episode)"
    }

    /// "S2E4" for a resume label.
    public static func episodeTag(_ episodeId: String) -> String? {
        guard let n = episodeNumbers(of: episodeId) else { return nil }
        if let s = n.season { return "S\(s)E\(n.episode)" }
        return "E\(n.episode)"
    }
}
