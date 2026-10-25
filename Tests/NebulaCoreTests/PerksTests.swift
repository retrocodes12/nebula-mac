import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NebulaCore

/// The Plus-level perks (10-25): which accent a tier may wear, the vote on what gets built next, and the
/// device-only watch log behind "Your month on Nebula".
final class PerksTests: XCTestCase {
    private func store() -> Store {
        Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-test-" + UUID().uuidString))
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 20) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: accents

    func testAnAccentNeedsItsTier() {
        XCTAssertEqual(Prefs.accentRank("#E50914"), 0)
        XCTAssertEqual(Prefs.accentRank("#f2f2f7"), 0, "case does not matter")
        XCTAssertEqual(Prefs.accentRank("#E0B24A"), 1)
        XCTAssertEqual(Prefs.accentRank("#FF7A5C"), 2)
        XCTAssertEqual(Prefs.accentRank("#123456"), 2, "a colour of one's own is the Plus level")
        XCTAssertEqual(Prefs.plusAccents.count, 6)
        XCTAssertTrue(Prefs.isHex("#a1B2c3"))
        XCTAssertFalse(Prefs.isHex("#a1B2c"))
        XCTAssertFalse(Prefs.isHex("a1B2c3f"))
        XCTAssertFalse(Prefs.isHex("#a1B2cg"))
    }

    func testAnAccentAboveTheTierFallsBackWithoutBeingForgotten() {
        XCTAssertEqual(Prefs.shownAccent("#E0B24A", rank: 0), Prefs.defaultAccent)
        XCTAssertEqual(Prefs.shownAccent("#E0B24A", rank: 1), "#E0B24A")
        XCTAssertEqual(Prefs.shownAccent("#B08CFF", rank: 1), Prefs.defaultAccent)
        XCTAssertEqual(Prefs.shownAccent("#b08cff", rank: 2), "#B08CFF")
        XCTAssertEqual(Prefs.shownAccent("#123abc", rank: 3), "#123ABC")
        XCTAssertEqual(Prefs.shownAccent("#0A84FF", rank: 0), "#0A84FF")
        XCTAssertEqual(Prefs.shownAccent("not a colour", rank: 3), Prefs.defaultAccent)
        // the stored choice stays as it was: the tier coming back brings it back
        let p = Prefs(store: store())
        p.accent = "#123ABC"
        XCTAssertEqual(Prefs.shownAccent(p.accent, rank: 1), Prefs.defaultAccent)
        XCTAssertEqual(p.accent, "#123ABC")
        XCTAssertEqual(Prefs.shownAccent(p.accent, rank: 2), "#123ABC")
    }

    // MARK: the vote

    func testAnOpenRoundBeforeOnesBallot() {
        let v = SupportVote.parse(JSON.object("""
        {"round":{"id":"ab12","title":"  What next?  ","closes":1793000000000,
                  "options":[{"id":"o1","title":"Watch parties","note":"On the Mac too"},{"id":"o2","title":"Downloads"},{"id":"","title":"no id"},{"id":"o4"}]},
         "mine":null,"can":true,"last":null}
        """)!)
        XCTAssertEqual(v.round?.title, "What next?")
        XCTAssertEqual(v.round?.closes, 1_793_000_000_000)
        XCTAssertEqual(v.round?.options.map(\.id), ["o1", "o2"], "an option with no id or title is dropped")
        XCTAssertEqual(v.round?.options.first?.note, "On the Mac too")
        XCTAssertNil(v.round?.options.first?.votes, "no counts before one's own ballot")
        XCTAssertNil(v.round?.voters)
        XCTAssertNil(v.mine)
        XCTAssertFalse(v.voted)
        XCTAssertTrue(v.can)
        XCTAssertNil(v.last)
    }

    func testAfterTheBallotTheCountsShow() {
        let v = SupportVote.parse(JSON.object("""
        {"round":{"id":"ab12","title":"","closes":1,"voters":3,
                  "options":[{"id":"o1","title":"A","votes":1},{"id":"o2","title":"B","votes":2},{"id":"o3","title":"C","votes":0}]},
         "mine":"o2","can":true}
        """)!)
        XCTAssertEqual(v.round?.title, "What should Nebula build next?", "an empty title gets the default question")
        XCTAssertEqual(v.round?.options.map { $0.votes }, [1, 2, 0], "a single vote is a count, not a yes")
        XCTAssertEqual(v.round?.voters, 3)
        XCTAssertEqual(v.mine, "o2")
        XCTAssertTrue(v.voted)
        // a ballot naming no option of the round is no ballot
        let odd = SupportVote.parse(["round": ["id": "x", "options": [["id": "o1", "title": "A"] as JSONObject]] as JSONObject, "mine": "o9"])
        XCTAssertNil(odd.mine)
        // a round with no usable option is no round
        XCTAssertNil(SupportVote.parse(["round": ["id": "x", "options": [] as [Any]] as JSONObject]).round)
    }

    func testNoRoundButTheLastResult() {
        let v = SupportVote.parse(JSON.object("""
        {"round":null,"mine":null,"can":false,
         "last":{"id":"zz","title":"Next?","closed":1790000000000,"winner":{"id":"o1","title":"Watch parties"},"voters":9,
                 "options":[{"id":"o1","title":"Watch parties","note":"","votes":6},{"id":"o2","title":"Downloads","votes":3}]}}
        """)!)
        XCTAssertNil(v.round)
        XCTAssertFalse(v.can)
        XCTAssertEqual(v.last?.winner, "Watch parties")
        XCTAssertEqual(v.last?.voters, 9)
        XCTAssertEqual(v.last?.options.map { $0.votes }, [6, 3])
        let none = SupportVote.parse(["last": ["id": "zz", "title": "Q", "winner": NSNull(), "voters": 0] as JSONObject])
        XCTAssertNil(none.last?.winner, "a round nobody voted in has no winner")
        XCTAssertEqual(SupportVote.parse([:]), SupportVote.empty)
    }

    func testSharesAddUpToAHundred() {
        XCTAssertEqual(SupportVote.shares([1, 1, 1]), [34, 33, 33])
        XCTAssertEqual(SupportVote.shares([2, 1]), [67, 33])
        XCTAssertEqual(SupportVote.shares([0, 0]), [0, 0])
        XCTAssertEqual(SupportVote.shares([5]), [100])
        XCTAssertEqual(SupportVote.shares([1, 2, 3, 4, 5, 6]).reduce(0, +), 100)
    }

    func testTheBallotGoesUpSignedAndRefusalsReadAsSentences() async throws {
        let s = store()
        s.setObject("cloud_link", ["gid": "g1", "token": "tok0"])
        let server = VoteServer()
        let cloud = Cloud(store: s, addons: AddonStore(store: s), progress: ProgressStore(store: s), library: LibraryStore(store: s),
                          transport: server, base: "https://c.test/cloud")
        let open = await cloud.loadVote()
        XCTAssertEqual(open?.round?.options.count, 2)
        let (voted, err) = await cloud.castVote("o2")
        XCTAssertNil(err)
        XCTAssertEqual(voted?.mine, "o2")
        XCTAssertEqual(voted?.round?.options.map { $0.votes }, [0, 1])
        let sent = await server.requests
        XCTAssertEqual(sent.last?.httpMethod, "POST")
        XCTAssertEqual(sent.last?.value(forHTTPHeaderField: "Authorization"), "Bearer g1.tok0")
        let body = try XCTUnwrap(JSON.object(sent.last?.httpBody ?? Data()))
        XCTAssertEqual(body.str("option"), "o2", "the field the server reads is `option`")
        await server.refuse(403, "vote needs plus")
        let (_, plus) = await cloud.castVote("o1")
        XCTAssertEqual(plus, "The vote is for Supporter Plus, Founders and Monthly supporters.")
        await server.refuse(404, "no vote open")
        let (_, closed) = await cloud.castVote("o1")
        XCTAssertEqual(closed, "That vote has just closed.")
        // signed out: nothing is sent
        s.set("cloud_link", nil)
        let out = Cloud(store: s, addons: AddonStore(store: s), progress: ProgressStore(store: s), library: LibraryStore(store: s),
                        transport: server, base: "https://c.test/cloud")
        let before = await server.requests.count
        let (_, signIn) = await out.castVote("o1")
        XCTAssertEqual(signIn, "Sign in first — your vote lives on your profile.")
        let after = await server.requests.count
        XCTAssertEqual(before, after)
    }

    // MARK: the watch log

    func testTheLogCountsOnlyWhileThePictureMoves() {
        let log = WatchLog(store: store(), calendar: utc)
        let d = day(2026, 10, 24)
        var t = 1000.0
        // 120 s of playing in quarter-second beats
        for _ in 0...480 { log.tick(title: "The Bear", playing: true, now: t, date: d); t += 0.25 }
        // paused for ten minutes: nothing
        log.tick(title: "The Bear", playing: false, now: t, date: d); t += 600
        // a beat after a long gap (a Mac asleep) starts a new run without counting the gap
        for _ in 0...40 { log.tick(title: "The Bear", playing: true, now: t, date: d); t += 0.25 }
        t += 30
        log.tick(title: "The Bear", playing: true, now: t, date: d)
        let r = log.recap("2026-10")
        XCTAssertEqual(r.total, 130)
        XCTAssertEqual(r.top, [WatchLog.Title(name: "The Bear", secs: 130)])
        XCTAssertEqual(r.days, 1)
        XCTAssertEqual(r.busiestDay, 24)
    }

    func testTheLogIsWrittenAndReadBack() {
        let s = store()
        let log = WatchLog(store: s, calendar: utc)
        var t = 0.0
        for _ in 0...40 { log.tick(title: "  Live   F1\n", playing: true, now: t, date: day(2026, 10, 2)); t += 0.5 }
        XCTAssertNil(s.string(WatchLog.key), "under 30 s waits in memory")
        log.flush(date: day(2026, 10, 2))
        let doc = s.object(WatchLog.key)
        XCTAssertEqual(doc.obj("2026-10")?.int("s"), 20)
        XCTAssertEqual(doc.obj("2026-10")?.obj("t")?.int("Live F1"), 20, "one line, trimmed")
        XCTAssertEqual(doc.obj("2026-10")?.obj("d")?.int("2"), 20)
        XCTAssertEqual(WatchLog(store: s, calendar: utc).recap("2026-10").total, 20)
        XCTAssertFalse(Cloud.syncKeys.contains(WatchLog.key), "never synced")
        XCTAssertTrue(Store.privateKeys.contains(WatchLog.key), "kept out of a phone's backups")
    }

    func testTheRecapsArithmetic() {
        var d: JSONObject = [:]
        WatchLog.add(&d, month: "2026-10", day: 3, title: "Film A", secs: 3000)
        WatchLog.add(&d, month: "2026-10", day: 3, title: "Show B", secs: 4000)
        WatchLog.add(&d, month: "2026-10", day: 9, title: "Show B", secs: 7000)
        WatchLog.add(&d, month: "2026-10", day: 12, title: "Clip", secs: 30)
        WatchLog.add(&d, month: "2026-10", day: 15, title: "Show C", secs: 3000)
        WatchLog.add(&d, month: "2026-10", day: 20, title: "Film D", secs: 7000)
        WatchLog.add(&d, month: "2026-10", day: 40, title: "Nowhere", secs: 99)
        let r = WatchLog.recap(d, month: "2026-10")
        XCTAssertEqual(r.total, 24_030)
        XCTAssertEqual(r.top.map(\.name), ["Show B", "Film D", "Film A"], "biggest first, ties by name")
        XCTAssertEqual(r.titles, 5)
        XCTAssertEqual(r.days, 4, "a day of 30 s is not a day you watched")
        XCTAssertEqual(r.busiestDay, 3, "7000 s on the 3rd and the 9th and the 20th: the earliest")
        XCTAssertEqual(r.busiestSecs, 7000)
        XCTAssertFalse(r.empty)
        XCTAssertTrue(WatchLog.recap(d, month: "2026-09").empty)
        XCTAssertEqual(WatchLog.hoursStat(42 * 60).value, "42")
        XCTAssertEqual(WatchLog.hoursStat(42 * 60).label, "minutes watched")
        XCTAssertEqual(WatchLog.hoursStat(r.total).value, "6.7")
        XCTAssertEqual(WatchLog.hoursStat(25 * 3600).value, "25", "a whole number loses its .0")
        XCTAssertEqual(WatchLog.hoursStat(3600).label, "hour watched")
        XCTAssertEqual(WatchLog.hoursStat(150 * 3600 + 1900).value, "151")
        XCTAssertEqual(WatchLog.length(7000), "1.9 h")
        XCTAssertEqual(WatchLog.length(30), "1 min")
        XCTAssertEqual(WatchLog.length(12 * 3600), "12 h")
        XCTAssertEqual(WatchLog.dayLabel("2026-10", 3), "3 Oct")
        XCTAssertEqual(WatchLog.monthName("2026-01"), "January")
    }

    func testOnlyThreeMonthsAndSoManyTitlesAreKept() {
        XCTAssertEqual(WatchLog.prevMonth("2026-01"), "2025-12")
        XCTAssertEqual(WatchLog.keptMonths("2026-02"), ["2026-02", "2026-01", "2025-12"])
        XCTAssertEqual(WatchLog.monthKey(day(2026, 3, 1), utc), "2026-03")
        var d: JSONObject = [:]
        for m in ["2025-10", "2025-11", "2025-12", "2026-01", "2026-02"] { WatchLog.add(&d, month: m, day: 1, title: "X", secs: 100) }
        WatchLog.prune(&d, now: "2026-02")
        XCTAssertEqual(Set(d.keys), ["2026-02", "2026-01", "2025-12"])
        var big: JSONObject = [:]
        for i in 0..<WatchLog.maxTitles { WatchLog.add(&big, month: "2026-10", day: 1, title: "T\(i)", secs: 100 + i) }
        WatchLog.add(&big, month: "2026-10", day: 1, title: "New one", secs: 1)
        let t = big.obj("2026-10")?.obj("t") ?? [:]
        XCTAssertEqual(t.count, WatchLog.maxTitles)
        XCTAssertEqual(t.int("New one"), 1, "the title being watched is always kept")
        XCTAssertNil(t["T0"], "the smallest other one goes")
        XCTAssertEqual(WatchLog.cleanTitle(String(repeating: "a", count: 200)).count, WatchLog.maxTitleLength)
        XCTAssertEqual(WatchLog.cleanTitle("   "), "Untitled")
    }

    func testTheMonthsOnTheCard() {
        let s = store()
        var d: JSONObject = [:]
        WatchLog.add(&d, month: "2026-08", day: 1, title: "X", secs: 100)
        WatchLog.add(&d, month: "2026-07", day: 1, title: "Too old", secs: 100)
        s.setObject(WatchLog.key, d)
        let log = WatchLog(store: s, calendar: utc)
        XCTAssertEqual(log.monthsShown(date: day(2026, 10, 1)), ["2026-10", "2026-08"], "this month always, the two before when they hold anything")
        XCTAssertEqual(log.nowKey(day(2026, 10, 1)), "2026-10")
    }
}

/// A stand-in for the cloud's vote routes: one open round, a ballot that moves the counts, and refusals on demand.
actor VoteServer: Transport {
    var requests: [URLRequest] = []
    private var mine: String?
    private var refusal: (Int, String)?

    func refuse(_ code: Int, _ error: String) { refusal = (code, error) }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if let r = refusal { return (JSON.data(["error": r.1]), r.0) }
        if request.httpMethod == "POST", let b = request.httpBody.flatMap({ JSON.object($0) }) { mine = b.str("option") }
        var options: [JSONObject] = [["id": "o1", "title": "Watch parties"], ["id": "o2", "title": "Downloads"]]
        if let m = mine { options = options.map { var o = $0; o["votes"] = o.str("id") == m ? 1 : 0; return o } }
        var round: JSONObject = ["id": "r1", "title": "What next?", "closes": 1_793_000_000_000, "options": options]
        if mine != nil { round["voters"] = 1 }
        return (JSON.data(["round": round, "mine": mine ?? NSNull(), "can": true, "last": NSNull()] as JSONObject), 200)
    }
}
