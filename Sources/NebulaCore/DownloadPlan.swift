import Foundation

/// What Downloads may keep and how it reads — the Android app's DownloadPlan.kt, word for word where they are words.
/// Only a finished file is kept here (Apple has no FFmpeg to save a playlist with, so a playlist is refused in its own
/// words); never a live stream, a protected one, a web player page or a torrent.
public enum DownloadPlan {
    public static let noLive = "Live streams can’t be downloaded. Try another stream."
    public static let noProtected = "Protected streams can’t be downloaded. Try another stream."
    public static let noKind = "This stream can’t be downloaded. Try another one."
    public static let noReach = "Couldn’t reach that stream. Try again, or try another one."
    public static let noPage = "That stream is a web page, not a video. Try another one."
    public static let noRoom = "Not enough room on this device for that download."
    public static let notReady = "That source isn’t ready yet. Try another one."
    public static let noPlaylist = "This stream comes in pieces, which this device can’t keep yet. Try a stream that is one file."

    /// Left free after a download: a device filled to the last byte stops working properly.
    public static let marginBytes: Int64 = 500 << 20
    /// Under this a "film" is a debrid host's "not ready yet" clip, not the film.
    public static let minFileBytes: Int64 = 20 << 20

    public enum Source: Equatable { case file(Int64), playlist, refused(String) }

    /// The row itself: is it worth offering? The stream's first bytes still decide ([sniff]).
    public static func savable(_ url: String, embedPage: Bool = false) -> Bool {
        if embedPage { return false }
        let u = url.trimmingCharacters(in: .whitespaces).lowercased()
        guard u.hasPrefix("http://") || u.hasPrefix("https://") else { return false }
        return u.range(of: #"\.mpd(\?|#|$)"#, options: .regularExpression) == nil
    }

    /// The whole size from a ranged answer's headers; 0 when the host does not say.
    public static func total(code: Int, contentRange: String?, contentLength: String?) -> Int64 {
        if let r = contentRange, let slash = r.lastIndex(of: "/"), let n = Int64(r[r.index(after: slash)...].trimmingCharacters(in: .whitespaces)) { return n }
        return code == 200 ? (Int64(contentLength?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0) : 0
    }

    /// What a stream's first bytes say it is. An address alone cannot tell: many carry no extension.
    public static func sniff(code: Int, contentType: String?, head: String, total: Int64) -> Source {
        guard (200...299).contains(code) else { return .refused(noReach) }
        let type = (contentType ?? "").lowercased()
        var text = head
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = String(text.drop(while: { $0.isWhitespace }))
        let low = String(text.prefix(256)).lowercased()
        if text.hasPrefix("#EXTM3U") || type.contains("mpegurl") { return .playlist }
        if low.contains("<mpd") || type.contains("dash+xml") { return .refused(noKind) }
        if type.contains("text/html") || low.hasPrefix("<!doctype") || low.hasPrefix("<html") { return .refused(noPage) }
        if total <= 0 { return .refused(noLive) }
        if total < minFileBytes { return .refused(notReady) }
        return .file(total)
    }

    public static func hasRoom(size: Int64, free: Int64) -> Bool { free - max(size, 0) >= marginBytes }

    public static func sizeText(_ b: Int64) -> String {
        if b >= 1 << 30 { return String(format: "%.1f GB", Double(b) / 1073741824) }
        if b >= 1 << 20 { return String(format: "%.0f MB", Double(b) / 1048576) }
        return "\(b / 1024) KB"
    }

    public enum Phase: String, Codable, Sendable { case queued, running, paused, done, failed }

    /// A row's status line.
    public static func line(_ phase: Phase, bytes: Int64, total: Int64, error: String = "") -> String {
        let pct = total > 0 ? String(format: "%.0f%%", min(99.9, Double(bytes) * 100 / Double(total))) : nil
        switch phase {
        case .done: return sizeText(bytes)
        case .failed: return "Couldn’t finish" + (error.isEmpty ? " · Tap to retry" : " · " + error)
        case .queued: return "Waiting to start"
        case .paused: return ["Paused", pct].compactMap { $0 }.joined(separator: " · ")
        case .running: return [pct, sizeText(bytes) + (total > 0 ? " of " + sizeText(total) : "")].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// A saved episode's name, split: the show, then what is left ("S1E2 · Name"). A film has no rest.
    public static func nameParts(_ name: String) -> (show: String, rest: String?) {
        let parts = name.components(separatedBy: " · ")
        if parts.count > 1, parts[1].trimmingCharacters(in: .whitespaces).range(of: #"^S\d+(E\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return (parts[0], parts.dropFirst().joined(separator: " · "))
        }
        return (name, nil)
    }

    /// Season and episode from a saved name, for the order inside a show.
    public static func numbers(_ name: String) -> (season: Int, episode: Int?)? {
        guard let rest = nameParts(name).rest else { return nil }
        let tag = rest.components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces).uppercased()
        guard tag.hasPrefix("S") else { return nil }
        let body = tag.dropFirst()
        let bits = body.split(separator: "E", omittingEmptySubsequences: false)
        guard let s = Int(bits[0]) else { return nil }
        return (s, bits.count > 1 ? Int(bits[1]) : nil)
    }

    /// One shelf per film or show, newest first; a show's episodes in playing order (specials last).
    public static func shelves<T>(_ rows: [T], name: (T) -> String, type: (T) -> String, id: (T) -> String, at: (T) -> Double) -> [(title: String, rows: [T])] {
        var order: [String] = []
        var groups: [String: (String, [T])] = [:]
        for r in rows.sorted(by: { at($0) > at($1) }) {
            let p = nameParts(name(r))
            let k = p.rest != nil ? "show/" + p.show : "one/" + type(r) + "/" + id(r)
            if groups[k] == nil { groups[k] = (p.show, []); order.append(k) }
            groups[k]!.1.append(r)
        }
        return order.map { k in
            let g = groups[k]!
            let sorted = g.1.sorted { a, b in
                let x = numbers(name(a)), y = numbers(name(b))
                let xs = x.map { $0.season == 0 ? Int.max : $0.season } ?? 0, ys = y.map { $0.season == 0 ? Int.max : $0.season } ?? 0
                if xs != ys { return xs < ys }
                return (x?.episode ?? 0) < (y?.episode ?? 0)
            }
            return (g.0, sorted)
        }
    }
}
