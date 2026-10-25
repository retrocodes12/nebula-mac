import Foundation

/// "Your month on Nebula" — how much this device actually played, per calendar month: the seconds the picture was
/// moving (never paused, never buffering), per title as the player names it (a series, a film, a live channel) and
/// per day of the month. The web's `watchlog_v1` and Android's WatchLog.kt.
///
/// Private by construction: its own file in the store, never synced, never sent, and on a phone left out of the
/// device's backups (Store.privateKeys). Kept: the current month and the two before it. Recorded for everyone, so
/// a new supporter sees their month so far; shown only from Supporter Plus up.
///
/// The document, the web's shape in whole seconds: `{"2026-10": {"s": 5400, "t": {"The Bear": 3600}, "d": {"24": 5400}}}`.
public final class WatchLog: @unchecked Sendable {
    public static let key = "watchlog_v1"
    /// The current month and the two before it.
    public static let keepMonths = 3
    /// A month keeps its biggest titles past this many (a channel-surfing month must not grow the file for ever).
    public static let maxTitles = 150
    public static let maxTitleLength = 80
    /// A day counts as a day you watched from a minute of it, and a title makes the top list from a minute too.
    public static let minuteSecs = 60
    /// A clock gap longer than this between two beats is not counted (a Mac asleep, a stalled main thread).
    static let maxStep: Double = 3
    /// Written after this many new seconds, and whenever the player closes (`flush`).
    static let saveEvery = 30

    let store: Store
    let calendar: Calendar
    private let lock = NSLock()
    private var doc: JSONObject?
    private var lastBeat: Double?
    private var pending: Double = 0
    private var pendingKey = ""
    private var unsaved = 0

    public init(store: Store, calendar: Calendar = .current) {
        self.store = store; self.calendar = calendar
    }

    /// One beat of the player's clock. `playing` = the picture is moving right now; the time since the last
    /// playing beat is added to `title` on today's date, and a beat that is not playing ends the run, so a pause or
    /// a buffering spell adds nothing. `now` is a monotonic clock in seconds.
    public func tick(title: String, playing: Bool, now: Double = ProcessInfo.processInfo.systemUptime, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard playing else { lastBeat = nil; return }
        let step = lastBeat.map { now - $0 } ?? 0
        lastBeat = now
        guard step > 0, step <= WatchLog.maxStep else { return }
        let month = WatchLog.monthKey(date, calendar), day = calendar.component(.day, from: date)
        let name = WatchLog.cleanTitle(title)
        let k = "\(month)|\(day)|\(name)"
        if k != pendingKey { pendingKey = k; pending = 0 }        // a new title or a new day: the part-second goes
        pending += step
        let secs = Int(pending)
        guard secs > 0 else { return }
        pending -= Double(secs)
        var d = loaded()
        WatchLog.add(&d, month: month, day: day, title: name, secs: secs)
        doc = d
        unsaved += secs
        if unsaved >= WatchLog.saveEvery { save(date) }
    }

    /// Write what is in memory (the player closing, the app leaving the screen).
    public func flush(date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastBeat = nil
        if unsaved > 0 { save(date) }
    }

    /// The months kept, newest first: the current month always, the two before it when they hold anything.
    public func monthsShown(date: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let now = WatchLog.monthKey(date, calendar), d = loaded()
        return WatchLog.keptMonths(now).filter { $0 == now || (d.obj($0)?.int("s") ?? 0) > 0 }
    }

    public func recap(_ month: String) -> Recap {
        lock.lock(); defer { lock.unlock() }
        return WatchLog.recap(loaded(), month: month)
    }

    public func nowKey(_ date: Date = Date()) -> String { WatchLog.monthKey(date, calendar) }

    private func loaded() -> JSONObject {
        if let d = doc { return d }
        let d = store.object(WatchLog.key)
        doc = d
        return d
    }

    private func save(_ date: Date) {
        var d = loaded()
        WatchLog.prune(&d, now: WatchLog.monthKey(date, calendar))
        doc = d
        store.setObject(WatchLog.key, d)
        unsaved = 0
    }

    // MARK: the pure part (WatchLogTests)

    /// "2026-10".
    public static func monthKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return monthKey(c.year ?? 1970, c.month ?? 1)
    }

    public static func monthKey(_ year: Int, _ month: Int) -> String {
        "\(year)-" + (month < 10 ? "0\(month)" : "\(month)")
    }

    /// The month before: "2026-01" → "2025-12".
    public static func prevMonth(_ key: String) -> String {
        let p = key.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]) else { return key }
        return m <= 1 ? monthKey(y - 1, 12) : monthKey(y, m - 1)
    }

    /// `now` and the two before it, newest first.
    public static func keptMonths(_ now: String) -> [String] {
        var out = [now]
        while out.count < keepMonths { out.append(prevMonth(out[out.count - 1])) }
        return out
    }

    /// A title as the log keys it: one line, trimmed, not endless; nothing becomes "Untitled".
    public static func cleanTitle(_ t: String) -> String {
        let one = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let cut = String(one.prefix(maxTitleLength))
        return cut.isEmpty ? "Untitled" : cut
    }

    /// Add `secs` to `title` on `day` of `month`.
    public static func add(_ d: inout JSONObject, month: String, day: Int, title: String, secs: Int) {
        guard secs > 0, (1...31).contains(day) else { return }
        var m = d.obj(month) ?? [:]
        m["s"] = m.int("s") + secs
        var titles = m.obj("t") ?? [:]
        let t = cleanTitle(title)
        titles[t] = titles.int(t) + secs
        if titles.count > maxTitles {
            // the smallest title that is not this one goes (the one being watched is always kept)
            if let small = titles.keys.filter({ $0 != t }).min(by: { (titles.int($0), $0) < (titles.int($1), $1) }) { titles[small] = nil }
        }
        m["t"] = titles
        var days = m.obj("d") ?? [:]
        days[String(day)] = days.int(String(day)) + secs
        m["d"] = days
        d[month] = m
    }

    /// Drop every month but `now` and the two before it.
    public static func prune(_ d: inout JSONObject, now: String) {
        let keep = Set(keptMonths(now))
        for k in d.keys where !keep.contains(k) { d[k] = nil }
    }

    public struct Title: Equatable, Sendable {
        public var name: String
        public var secs: Int
    }

    /// One month, added up for the card.
    public struct Recap: Equatable, Sendable {
        public var month: String
        public var total: Int
        /// Days with at least a minute.
        public var days: Int
        /// The three biggest titles (a minute each at least), biggest first; ties by name.
        public var top: [Title]
        public var titles: Int
        /// The day of the month with the most (the earlier on a tie), and its seconds; 0 when no day counts.
        public var busiestDay: Int
        public var busiestSecs: Int
        /// Under a minute in it: the card says so instead.
        public var empty: Bool { total < WatchLog.minuteSecs }
    }

    public static func recap(_ d: JSONObject, month: String) -> Recap {
        guard let m = d.obj(month) else { return Recap(month: month, total: 0, days: 0, top: [], titles: 0, busiestDay: 0, busiestSecs: 0) }
        let t = m.obj("t") ?? [:], days = m.obj("d") ?? [:]
        let titles = t.keys.map { Title(name: $0, secs: t.int($0)) }.filter { $0.secs > 0 }
        let top = titles.filter { $0.secs >= minuteSecs }
            .sorted { $0.secs != $1.secs ? $0.secs > $1.secs : $0.name < $1.name }
        let dayRows = days.keys.compactMap { k in Int(k).map { ($0, days.int(k)) } }.filter { $0.1 >= minuteSecs }
        let busiest = dayRows.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.first
        return Recap(month: month, total: m.int("s"), days: dayRows.count, top: Array(top.prefix(3)), titles: titles.count,
                     busiestDay: busiest?.0 ?? 0, busiestSecs: busiest?.1 ?? 0)
    }

    /// The month's big figure and what it counts: minutes below an hour ("42", "minutes watched"), then hours to
    /// one place ("12.4", a whole "25" without its ".0"), whole from a hundred up.
    public static func hoursStat(_ secs: Int) -> (value: String, label: String) {
        if secs < 3600 { let m = secs / 60; return ("\(m)", m == 1 ? "minute watched" : "minutes watched") }
        let h = Double(secs) / 3600
        var v = h < 100 ? String(format: "%.1f", h) : String(Int(h.rounded()))
        if v.hasSuffix(".0") { v.removeLast(2) }
        return (v, v == "1" ? "hour watched" : "hours watched")
    }

    /// A length beside a title: "42 min" below an hour, "3.4 h" below ten, whole hours above.
    public static func length(_ secs: Int) -> String {
        if secs < 3600 { return "\(max(1, secs / 60)) min" }
        let h = Double(secs) / 3600
        return h < 10 ? String(format: "%.1f h", h) : "\(Int(h.rounded())) h"
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    /// "2026-10" → "October".
    public static func monthName(_ key: String) -> String {
        guard let m = Int(key.split(separator: "-").last ?? ""), (1...12).contains(m) else { return key }
        return monthNames[m - 1]
    }

    /// "2026-10" → "Oct".
    public static func monthShort(_ key: String) -> String { String(monthName(key).prefix(3)) }

    /// ("2026-10", 24) → "24 Oct".
    public static func dayLabel(_ key: String, _ day: Int) -> String { "\(day) \(monthShort(key))" }
}
