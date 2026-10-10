import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One picture of a Seekr preview track: [start, end) in the SOURCE's timebase (seconds), and the
/// region of a sprite sheet it is cut from.
public struct SeekrCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var sheet: String
    public var x: Int, y: Int, w: Int, h: Int
}

/// Seekr previews with the viewer's OWN seekr.tv key: ready-made scrub pictures, looked up by the
/// title's id and length. The key never goes anywhere but Seekr (asked straight from the device)
/// and the viewer's own profile (the synced doc `seekr` = {key, at}, newest wins — the shared
/// player's and Android's wire shape). One lookup per title and length a run; a refused key (401)
/// is said once and stops, the day's limit (429) stops quietly, no previews (404) is remembered.
public enum Seekr {
    public static let api = "https://api.seekr.tv"

    public static func validKey(_ k: String) -> Bool {
        k.range(of: #"^sk_live_[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    /// The lookup's id parameters, or nil when this title gets none.
    public static func query(type: String, id: String) -> [(String, String)]? {
        let v = id.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        let t = type.lowercased()
        guard t == "movie" || t == "series" else { return nil }
        func m(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let r = re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) else { return nil }
            return (0..<r.numberOfRanges).map { i in Range(r.range(at: i), in: v).map { String(v[$0]) } ?? "" }
        }
        func num(_ s: String) -> String { String(Int(s) ?? 0) }
        if t == "movie" {
            if m(#"tt\d{5,10}"#) != nil { return [("imdb_id", v)] }
            if let g = m(#"tmdb:([1-9]\d{0,9})"#) { return [("tmdb_id", g[1])] }
        } else {
            if let g = m(#"(tt\d{5,10}):(\d{1,4}):(\d{1,5})"#) { return [("show_imdb_id", g[1]), ("season", num(g[2])), ("episode", num(g[3]))] }
            if let g = m(#"tmdb:([1-9]\d{0,9}):(\d{1,4}):(\d{1,5})"#) { return [("show_tmdb_id", g[1]), ("season", num(g[2])), ("episode", num(g[3]))] }
        }
        return nil
    }

    /// "01:02:03.450" / "02:03.450" / "02:03" → seconds.
    public static func parseTime(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"^(?:(\d{1,3}):)?([0-5]?\d):([0-5]?\d)(?:[.,](\d{1,3}))?$"#),
              let r = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> String { Range(r.range(at: i), in: t).map { String(t[$0]) } ?? "" }
        let h = Double(g(1)) ?? 0, mi = Double(g(2)) ?? 0, se = Double(g(3)) ?? 0
        var frac = g(4)
        while !frac.isEmpty && frac.count < 3 { frac += "0" }
        return (h * 60 + mi) * 60 + se + (Double(frac) ?? 0) / 1000
    }

    public static let maxCues = 20_000

    /// Seekr's WEBVTT: per cue a timing line, then exactly one line — an absolute https tile
    /// address ending `#xywh=x,y,w,h`. A cue with no usable payload is dropped. Sorted by start.
    public static func parseVtt(_ text: String) -> [SeekrCue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \t")).hasPrefix("WEBVTT") else { return [] }
        var out: [SeekrCue] = []
        var i = 1
        while i < lines.count && out.count < maxCues {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            guard let arrow = l.range(of: "-->") else { i += 1; continue }
            let a = parseTime(String(l[..<arrow.lowerBound]))
            let after = l[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let b = parseTime(String(after.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""))
            let payload = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
            // a cue with no payload line must not swallow the next cue's timing line
            i += payload.contains("-->") ? 1 : 2
            guard let s = a, let e = b, e >= s, let c = cue(s, e, payload) else { continue }
            out.append(c)
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func cue(_ a: Double, _ b: Double, _ payload: String) -> SeekrCue? {
        guard let hash = payload.lastIndex(of: "#"), hash > payload.startIndex else { return nil }
        let url = String(payload[..<hash])
        guard url.lowercased().hasPrefix("https://"), !url.contains(where: \.isWhitespace) else { return nil }
        let frag = String(payload[payload.index(after: hash)...])
        guard frag.hasPrefix("xywh=") else { return nil }
        let n = frag.dropFirst(5).split(separator: ",").compactMap { Int($0) }
        guard n.count == 4, n[2] > 0, n[3] > 0, n[0] >= 0, n[1] >= 0 else { return nil }
        return SeekrCue(start: a, end: b, sheet: url, x: n[0], y: n[1], w: n[2], h: n[3])
    }

    /// The cue for the PLAYER's position `pos` (seconds): the source position is pos / scale, the
    /// cue is the last one starting at or before it, and past its midpoint the next one (nearer).
    /// Before the first → the first. -1 when there are none.
    public static func cueIndex(_ cues: [SeekrCue], pos: Double, scale: Double) -> Int {
        guard !cues.isEmpty else { return -1 }
        let s = scale.isFinite && scale > 0 ? scale : 1
        let p = max(0, pos) / s
        var lo = 0, hi = cues.count - 1, at = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= p { at = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if at < 0 { return 0 }
        let c = cues[at]
        return at + 1 < cues.count && p > (c.start + c.end) / 2 ? at + 1 : at
    }

    // MARK: the synced doc

    /// {key: "sk_live_…" or "" (disconnected), at: epoch ms} when well-formed, else nil.
    public static func read(_ remote: JSONObject) -> (key: String, at: Int64)? {
        guard let k = remote["key"] as? String else { return nil }
        if !k.isEmpty && !validKey(k) { return nil }
        let at = remote.int64("at")
        guard at > 0 else { return nil }
        return (k, at)
    }

    // MARK: the network

    public enum Check: Sendable { case ok, refused, unreachable }

    public struct Track: Sendable {
        public var cues: [SeekrCue]
        public var scale: Double
    }

    public enum Lookup: Sendable {
        case found(Track)
        /// Seekr has nothing for this title at this length.
        case none
        /// The key was refused (401): say so once and stop asking with it.
        case refused
        /// The day's allowance is spent (429), or Seekr could not be reached: quiet.
        case quiet
    }

    /// GET /v1/keys/validate — costs no allowance.
    public static func validate(_ key: String, transport: Transport = URLSessionTransport(timeout: 15)) async -> Check {
        guard validKey(key), let url = URL(string: api + "/v1/keys/validate") else { return .refused }
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "X-API-Key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, code) = try? await transport.send(r) else { return .unreachable }
        if code == 401 { return .refused }
        guard (200...299).contains(code), let o = JSON.object(data), o["valid"] != nil else { return .unreachable }
        return o.bool("valid") ? .ok : .refused
    }

    /// One lookup, then its VTT (no key on that hop).
    public static func lookup(key: String, query q: [(String, String)], durationMs: Int64, transport: Transport = URLSessionTransport(timeout: 15)) async -> Lookup {
        guard validKey(key), durationMs > 0, var comps = URLComponents(string: api + "/sprites") else { return .quiet }
        comps.queryItems = [URLQueryItem(name: "duration_ms", value: String(durationMs))] + q.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { return .quiet }
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "X-API-Key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, code) = try? await transport.send(r) else { return .quiet }
        switch code {
        case 401: return .refused
        case 404: return .none
        case 200...299: break
        default: return .quiet
        }
        guard let o = JSON.object(data), let vtt = o.text("vtt_url"), vtt.lowercased().hasPrefix("https://"), let vurl = URL(string: vtt) else { return .quiet }
        let sc = o.num("scale")
        let scale = sc.isFinite && sc > 0 ? sc : 1
        guard let (vdata, vcode) = try? await transport.send(URLRequest(url: vurl)), (200...299).contains(vcode),
              vdata.count <= 4_000_000, let text = String(data: vdata, encoding: .utf8) else { return .quiet }
        let cues = parseVtt(text)
        return cues.isEmpty ? .none : .found(Track(cues: cues, scale: scale))
    }
}
