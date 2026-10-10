import Foundation

/// The rules behind the loopback playlist path (the app's `ManifestProxy` serves them): an HLS
/// stream whose host wants its own request headers on every piece, and whose pieces may come
/// wrapped in a picture.
///
/// Some sports hosts hand out their pieces as a small PNG with the video glued on behind it
/// (measured 10-11: a 70-byte PNG header, then a clean 1080p H.264 + AAC transport stream). The
/// engine's reader takes such a piece for a picture, and refuses the address before that because
/// it does not end in a video extension. So the playlist is served from loopback with every piece
/// renamed to a loopback address that DOES end in one (`.ts`, the real address encoded in the path
/// — a query string would hide the extension from the reader), and each piece is handed over from
/// its first transport packet on.
public enum HlsUnwrap {
    /// A playlist this path is meant for: an http(s) address whose path names an HLS playlist.
    public static func isPlaylist(_ address: String) -> Bool {
        guard let u = URL(string: address), let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return u.path.lowercased().hasSuffix(".m3u8")
    }

    /// An address inside a loopback path: base64url, no padding, no dots.
    public static func encode(_ address: String) -> String {
        Data(address.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let t = String(data: d, encoding: .utf8),
              let u = URL(string: t), let sch = u.scheme?.lowercased(), sch == "http" || sch == "https" else { return nil }
        return t
    }

    /// What a loopback path asks for.
    public enum Ask: Equatable {
        /// A playlist (the first, or a variant/rendition the first named).
        case playlist(String)
        /// A media piece, handed over unwrapped.
        case piece(String)
        /// Anything else a playlist names (a key, an init section): passed on as it is.
        case raw(String)
    }

    /// `p/<enc>.m3u8`, `s/<enc>.ts`, `r/<enc>.bin` — the part of the path after the token.
    public static func ask(_ rest: String) -> Ask? {
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let dot = parts[1].firstIndex(of: ".") else { return nil }
        guard let address = decode(String(parts[1][..<dot])) else { return nil }
        switch parts[0] {
        case "p": return .playlist(address)
        case "s": return .piece(address)
        case "r": return .raw(address)
        default: return nil
        }
    }

    /// The playlist with every address it names turned into a loopback one under `prefix`
    /// (e.g. "http://127.0.0.1:5000/h/<token>/"), resolved against `base` (where the text finally
    /// came from — a redirected playlist's relative pieces belong to the address it landed on).
    public static func rewrite(_ text: String, base: String, prefix: String) -> String {
        guard let baseURL = URL(string: base) else { return text }
        func resolve(_ ref: String) -> String? {
            guard let u = URL(string: ref, relativeTo: baseURL)?.absoluteURL,
                  let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
            return u.absoluteString
        }
        var out: [String] = []
        var nextIsPlaylist = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out.append(raw); continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF") { nextIsPlaylist = true }
                out.append(rewriteURIs(raw, playlist: line.hasPrefix("#EXT-X-MEDIA") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF"),
                                       resolve: resolve, prefix: prefix))
                continue
            }
            guard let abs = resolve(line) else { out.append(raw); continue }
            let playlist = nextIsPlaylist || isPlaylist(abs)
            nextIsPlaylist = false
            out.append(prefix + (playlist ? "p/\(encode(abs)).m3u8" : "s/\(encode(abs)).ts"))
        }
        return out.joined(separator: "\n")
    }

    /// `URI="…"` inside a tag: a rendition's playlist goes through the playlist path, a key or an
    /// init section through the raw one (it needs the same headers, and must not be cut).
    private static func rewriteURIs(_ line: String, playlist: Bool, resolve: (String) -> String?, prefix: String) -> String {
        guard let r = line.range(of: "URI=\"") else { return line }
        let start = r.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return line }
        let ref = String(line[start..<end])
        // a key given inline (data:, skd:) is left alone
        guard let abs = resolve(ref) else { return line }
        let loop = prefix + (playlist ? "p/\(encode(abs)).m3u8" : "r/\(encode(abs)).bin")
        return String(line[..<start]) + loop + String(line[end...])
    }

    /// Where the transport stream inside a piece starts: 0 for a plain one, the first of three
    /// packets in a row (188 bytes apart) within the first 64 KB for a wrapped one, nil when
    /// there is none to find — the piece is then passed on whole (fMP4, AAC, whatever it is).
    public static func tsStart(_ d: Data) -> Int? {
        let n = d.count
        guard n >= 188 * 3 else { return nil }
        return d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Int? in
            let b = p.bindMemory(to: UInt8.self)
            if b[0] == 0x47 && b[188] == 0x47 && b[376] == 0x47 { return 0 }
            let limit = min(n - 188 * 2, 65_536)
            var i = 1
            while i < limit {
                if b[i] == 0x47 && b[i + 188] == 0x47 && b[i + 376] == 0x47 { return i }
                i += 1
            }
            return nil
        }
    }

    /// The piece as the engine should see it.
    public static func unwrap(_ d: Data) -> Data {
        guard let at = tsStart(d), at > 0 else { return d }
        return d.subdata(in: d.startIndex + at ..< d.endIndex)
    }
}
