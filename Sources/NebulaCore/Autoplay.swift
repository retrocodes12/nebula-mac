import Foundation

/// Autoplay the best stream (the iPhone; Android's Autoplay.kt, the shared player's "shelf mode"): Play on a film or an
/// episode starts its best stream with no list. The rules alone — which row is best, when to stop waiting for slower
/// add-ons, a debrid clip in place of the film — pure, so AutoplayTests pin them; the card, the run and the player's
/// part live in the phone's shell (Sources/NebulaIOS/Autoplay*.swift).
public enum Autoplay {
    /// The settings (Settings › Autoplay the best stream) with their defaults. `max` = the quality rank aimed for (4K = 4).
    public struct Cfg: Equatable, Sendable {
        public var max: Int
        public var instant: Bool
        /// "quick" / "balanced" / "all"
        public var wait: String
        /// 0 / 3 / 5
        public var retry: Int
        /// 20 / 45 / 90: seconds a pick has to show its first picture
        public var startS: Int
        /// "title" / "list"
        public var back: String

        public init(max: Int = 4, instant: Bool = true, wait: String = "balanced", retry: Int = 5, startS: Int = 45, back: String = "title") {
            self.max = max; self.instant = instant; self.wait = wait; self.retry = retry; self.startS = startS; self.back = back
        }
    }

    /// One row of a title's streams and the add-on that gave it.
    public struct Row: Equatable, Sendable {
        public var stream: StreamItem
        public var addon: Addon
        public init(_ stream: StreamItem, _ addon: Addon) { self.stream = stream; self.addon = addon }
    }

    /// A row of a debrid service: ready to play at once, not in the service's cloud yet, or a button for the account.
    public enum Debrid: Equatable, Sendable { case none, ready, wait, action }

    static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // the patterns are literals in this file; a bad one is a programming error
        try! NSRegularExpression(pattern: p, options: o)
    }

    // Comet names a file the service holds "[TB⚡] Comet 2160p" and one it would first fetch "[TB⬇️] …"; Torrentio-style
    // add-ons write "[TB+]" and "[TB download]"; "[TB🔄] Comet Sync" is a button, not a film
    static let reDeb = rx(#"\[[A-Za-z]{2,3} ?(⚡|\+|⬇|⏳|download)"#, .caseInsensitive)
    static let reTorBox = rx(#"^\s*\[TB\b|torbox"#, .caseInsensitive)
    static let reDebAddon = rx(#"\b(TB|RD|AD|PM)\b"#)
    static let reDebWord = rx(#"torbox|debrid|premiumize"#, .caseInsensitive)

    static func hit(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func debrid(name: String, url: String) -> Debrid {
        // by scalar: "🔄" may come with a variation selector, which makes it another Character
        if name.unicodeScalars.contains(where: { $0.value == 0x1F504 }) || url.contains("/debrid-sync/") { return .action }
        // the mark read as UTF-16: "⬇️" is one Character with its variation selector, and a range ending inside it
        // has no String index
        guard let m = reDeb.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)) else { return .none }
        let mark = (name as NSString).substring(with: m.range(at: 1))
        return mark == "⚡" || mark == "+" ? .ready : .wait
    }
    public static func debrid(_ s: StreamItem) -> Debrid { debrid(name: s.name, url: s.url) }
    /// Never picked by itself: a debrid row that is not ready yet, or a button.
    public static func held(_ s: StreamItem) -> Bool { let d = debrid(s); return d == .wait || d == .action }
    /// 2 = ready in one service named in the row ("[TB…]"), 1 = ready in another, 0 = any other row.
    public static func instant(_ s: StreamItem) -> Int {
        guard debrid(s) == .ready else { return 0 }
        return hit(reTorBox, s.name) ? 2 : 1
    }
    /// A debrid add-on by its name ("Comet | ElfHosted | TB", "Torrentio RD"): one still being asked may yet have a 4K.
    public static func debridAddon(_ name: String) -> Bool { hit(reDebAddon, name) || hit(reDebWord, name) }

    /// 4K = 4, 1080 = 3, 720 = 2, SD = 1, unknown = 0.
    public static func quality(_ s: StreamItem) -> Int { StreamBadges.resRank(s.name + "\n" + s.title) }
    /// Quality as the pick sees it: a row above "Aim for" ranks just under the rows at it, and over the lower ones.
    public static func capped(_ q: Int, _ max: Int) -> Double { q > max ? Double(max) - 0.5 : Double(q) }

    /// Rows best first: `keepWaiting` false (the pick) drops held rows; true (the player's Streams list) sinks the
    /// not-ready ones to the end and drops only buttons. Then ready-in-a-service first (when `Cfg.instant`), quality
    /// capped at "Aim for", one this connection carries, one this device decodes smoothly; ties keep the add-on order.
    /// (Torrent rows never reach here: the add-on client keeps only rows with a web address.)
    public static func rank(_ rows: [Row], _ cfg: Cfg, slow: (StreamItem) -> Bool = { _ in false },
                            stutter: (StreamItem) -> Bool = { _ in false }, keepWaiting: Bool = false) -> [Row] {
        let keyed: [(row: Row, i: Int, k: [Double])] = rows
            .filter { debrid($0.stream) != .action && (keepWaiting || !held($0.stream)) }
            .enumerated().map { i, r in
                let s = r.stream
                return (r, i, [
                    held(s) ? 0 : 1,
                    cfg.instant ? Double(instant(s)) : 0,
                    capped(quality(s), cfg.max),
                    slow(s) ? 0 : 1,
                    stutter(s) ? 0 : 1,
                ])
            }
        return keyed.sorted { x, y in
            for j in x.k.indices where x.k[j] != y.k[j] { return x.k[j] > y.k[j] }
            return x.i < y.i
        }.map(\.row)
    }

    /// What the streams page does next while the add-ons answer.
    public enum Verdict: Equatable, Sendable { case wait, pick, settle, none }

    public static let quickMs = 8_000
    public static let balancedMs = 25_000
    public static let capMs = 90_000

    /// When to pick ("Wait for add-ons"): `best` = the best row so far (nil = none), `asking` = the add-ons still being
    /// asked, by name. pick = now (the page waits 300 ms for a row arriving with it); settle = every add-on answered
    /// (pick after ~700 ms); none = nothing playable came, the list stays.
    /// Quick: the best so far is instant or at the aimed quality, else at 8 s with whatever is there. Balanced: instant
    /// AND at the aimed quality, or instant with no debrid add-on still asked; else at 25 s (nothing yet: on to 90 s).
    /// All: every add-on (90 s at most).
    public static func verdict(_ cfg: Cfg, elapsedMs: Int, best: StreamItem?, asking: [String], allAnswered: Bool) -> Verdict {
        if allAnswered { return best == nil ? .none : .settle }
        if elapsedMs >= capMs { return best == nil ? .none : .pick }
        guard let best = best else { return .wait }
        let inst = instant(best) > 0
        let at = quality(best) >= cfg.max
        switch cfg.wait {
        case "quick": return inst || at || elapsedMs >= quickMs ? .pick : .wait
        case "all": return .wait
        default:
            return (inst && (at || !asking.contains(where: debridAddon))) || elapsedMs >= balancedMs ? .pick : .wait
        }
    }

    /// A debrid row that sent a few seconds instead of the film (Comet's 8 s "not ready" clip): never a start, never watched.
    public static func briefClip(name: String, url: String, type: String?, durationMs: Int) -> Bool {
        let d = debrid(name: name, url: url)
        return (d == .ready || d == .wait) && (type == "movie" || type == "series") && (1..<30_000).contains(durationMs)
    }

    /// The next row to try after `failed` ones and the one that just failed (`cur`), from the ranked `queue`.
    public static func next(_ queue: [Row], cur: String, failed: Set<String>) -> Row? {
        queue.first { $0.stream.url != cur && !failed.contains($0.stream.url) }
    }

    /// "4K" / "1080p" / "720p" / "SD" / "" — as the card and the Streams list say it.
    public static func qualityWord(_ s: StreamItem) -> String {
        switch StreamBadges.plate(s.name + "\n" + s.title)?.res {
        case "4K": return "4K"
        case "1080": return "1080p"
        case "720": return "720p"
        case "SD": return "SD"
        default: return ""
        }
    }

    /// The card's line for a start: "Starting 4K · Comet · instant" / "That one didn’t play · trying 1080p · Comet".
    public static func startLine(_ s: StreamItem, addonName: String, why: String? = nil) -> String {
        let lead: String
        switch why {
        case nil: lead = "Starting"
        case "slow": lead = "That one was slow to start · trying"
        case "brief": lead = "That one wasn\u{2019}t ready · trying"
        default: lead = "That one didn\u{2019}t play · trying"
        }
        let q = qualityWord(s)
        return lead + (q.isEmpty ? "" : " \(q)") + (addonName.isEmpty ? "" : " · \(addonName)") + (instant(s) > 0 ? " · instant" : "")
    }

    /// "Asking A and B for streams…" / "Found 12 streams · still asking A" / "Found 12 streams · picking the best".
    public static func askLine(found: Int, asking: [String]) -> String {
        let who: String
        switch asking.count {
        case 0: who = ""
        case 1: who = asking[0]
        case 2: who = asking[0] + " and " + asking[1]
        default: who = "\(asking.count) add-ons"
        }
        if found > 0 {
            return "Found \(found) stream" + (found > 1 ? "s" : "") + (asking.isEmpty ? " · picking the best" : " · still asking \(who)")
        }
        return asking.isEmpty ? "Finding the best stream…" : "Asking \(who) for streams…"
    }

    /// The player's Streams list: this title's rows best first (15 at most), each as (label, address); look-alikes say
    /// where they come from, a row that failed says so, a debrid row not ready yet says so.
    public static func menu(cur: String, cfg: Cfg, rows: [Row], failed: Set<String>) -> [(label: String, url: String)] {
        let ranked = Array(rank(Array(rows.prefix(400)), cfg, keepWaiting: true).prefix(15))
        func base(_ r: Row) -> String {
            let s = r.stream
            let bytes = s.videoSize > 0 ? s.videoSize : sizeIn(s.name + "\n" + s.title)
            let size = bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : bytes > 0 ? "\(bytes / 1_000_000) MB" : ""
            return [qualityWord(s), r.addon.name, instant(s) > 0 ? "Instant" : "", size].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let labels = ranked.map(base)
        return ranked.enumerated().map { i, r in
            var label = labels[i].isEmpty ? "Stream" : labels[i]
            if labels.filter({ $0 == labels[i] }).count > 1, var h = URL(string: r.stream.url)?.host, !h.isEmpty {
                if h.hasPrefix("www.") { h.removeFirst(4) }
                label += " · " + h
            }
            if r.stream.url != cur && failed.contains(r.stream.url) { label += " — did not play" }
            else if debrid(r.stream) == .wait { label += " — not ready yet" }
            return (label, r.stream.url)
        }
    }

    static let reSize = rx(#"(\d+(?:[.,]\d+)?)\s*(GB|GiB|MB|MiB)\b"#, .caseInsensitive)

    /// A size the row's text names ("💾 4.2 GB"), in bytes; 0 = none.
    static func sizeIn(_ text: String) -> Int64 {
        guard let m = reSize.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let nr = Range(m.range(at: 1), in: text), let ur = Range(m.range(at: 2), in: text),
              let n = Double(text[nr].replacingOccurrences(of: ",", with: ".")) else { return 0 }
        let u = text[ur].lowercased()
        let mult: Double = u == "gb" ? 1e9 : u == "gib" ? 1_073_741_824 : u == "mb" ? 1e6 : 1_048_576
        return Int64(n * mult)
    }
}

extension Prefs {
    /// Autoplay the best stream (the iPhone; off by default). The web player's keys, device-local like every pref here.
    public var bestPlay: Bool {
        get { (value("bestPlay") as? Bool) ?? false }
        set { setValue("bestPlay", newValue) }
    }
    /// Aim for 2160 / 1080 / 720.
    public var apMax: Int {
        get { let v = (value("apMax") as? NSNumber)?.intValue ?? 2160; return [2160, 1080, 720].contains(v) ? v : 2160 }
        set { setValue("apMax", newValue) }
    }
    /// Debrid rows that are ready play before higher quality.
    public var apInstant: Bool {
        get { (value("apInstant") as? Bool) ?? true }
        set { setValue("apInstant", newValue) }
    }
    /// quick / balanced / all
    public var apWait: String {
        get { let v = (value("apWait") as? String) ?? "balanced"; return v == "quick" || v == "all" ? v : "balanced" }
        set { setValue("apWait", newValue) }
    }
    /// A start that fails: try the next 0 / 3 / 5.
    public var apRetry: Int {
        get { let v = (value("apRetry") as? NSNumber)?.intValue ?? 5; return v == 0 || v == 3 ? v : 5 }
        set { setValue("apRetry", newValue) }
    }
    /// Seconds a start has to show a picture: 20 / 45 / 90.
    public var apStart: Int {
        get { let v = (value("apStart") as? NSNumber)?.intValue ?? 45; return v == 20 || v == 90 ? v : 45 }
        set { setValue("apStart", newValue) }
    }
    /// Back from its player: "title" (the title page) or "list" (the streams list).
    public var apBack: String {
        get { (value("apBack") as? String) == "list" ? "list" : "title" }
        set { setValue("apBack", newValue) }
    }
    /// The six options as the rules read them.
    public var autoplay: Autoplay.Cfg {
        Autoplay.Cfg(max: apMax == 1080 ? 3 : apMax == 720 ? 2 : 4, instant: apInstant, wait: apWait, retry: apRetry,
                     startS: apStart, back: apBack)
    }
}
