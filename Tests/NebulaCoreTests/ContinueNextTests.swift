import XCTest
import Foundation
@testable import NebulaCore

/// 0.9.0: Continue watching the Nuvio way, the content advisory and the age rating — the same cases as the shared
/// player's `cwflow` / `advisory` rigs and Android's `ContinueNextTest` / `AgeRegionTest`.
final class ContinueNextTests: XCTestCase {
    let day: Int64 = 86_400_000
    let now: Int64 = 1_800_000_000_000

    func rec(_ id: String, _ at: Int64, pos: Double = 0, dur: Double = 0, done: Bool = false, hand: Bool = false, type: String = "series") -> ProgressRec {
        var r = ProgressRec(type: type, id: id); r.name = id; r.pos = pos; r.dur = dur; r.done = done; r.hand = hand; r.at = at
        return r
    }
    func ans(_ sig: Int64, _ ep: ContinueNext.Ep?, same: Bool = true) -> ContinueNext.Answer {
        var a = ContinueNext.Answer(sig: sig, t: now); a.name = "Show"; a.poster = "p"; a.back = "b"; a.same = same; a.ep = ep
        return a
    }
    func ep(_ id: String, _ s: Int, _ e: Int, rel days: Int64) -> ContinueNext.Ep {
        let d = Date(timeIntervalSince1970: Double(now + days * day) / 1000)
        return ContinueNext.Ep(id: id, s: s, e: e, name: "Ep \(s).\(e)", thumb: nil, rel: ISO8601DateFormatter().string(from: d))
    }
    func plan(_ recs: [ProgressRec], _ answers: [String: ContinueNext.Answer] = [:], unaired: Bool = false, nextOn: Bool = true,
              wanted: inout [String]) -> [ProgressRec] {
        var w: [String] = []
        let out = ContinueNext.plan(all: Dictionary(uniqueKeysWithValues: recs.map { (ProgressStore.key($0.type, $0.id), $0) }),
                                    off: [], nextOn: nextOn, unaired: unaired, now: now, answer: { answers[$0.id] }, want: { w.append($0.id) })
        wanted += w
        return out
    }
    func plan(_ recs: [ProgressRec], _ answers: [String: ContinueNext.Answer] = [:], unaired: Bool = false, nextOn: Bool = true) -> [ProgressRec] {
        var w: [String] = []
        return plan(recs, answers, unaired: unaired, nextOn: nextOn, wanted: &w)
    }

    func testOnePerShow_theNewestResumePoint() {
        let out = plan([rec("tt1:1:1", now - 7 * day, pos: 500, dur: 2400), rec("tt1:1:2", now - 6 * day, pos: 900, dur: 2400)])
        XCTAssertEqual(out.map(\.id), ["tt1:1:2"])
    }

    func testFinished_upNextFromTheAnswer_askedWhenUnknown() {
        let done = rec("tt1:1:1", now - 3 * day, done: true)
        var wanted: [String] = []
        XCTAssertTrue(plan([done], wanted: &wanted).isEmpty)
        XCTAssertEqual(wanted, ["tt1"])
        let out = plan([done], ["tt1": ans(done.at, ep("tt1:1:2", 1, 2, rel: -1))])
        XCTAssertEqual(out.first?.id, "tt1:1:2")
        XCTAssertEqual(out.first?.next, true)
        XCTAssertEqual(out.first?.seriesId, "tt1")
        XCTAssertEqual(out.first?.fresh, true, "out after the finish = New episode")
    }

    func testNewerPartWay_isResumedInstead() {
        let out = plan([rec("tt1:1:1", now - 5 * day, done: true), rec("tt1:1:2", now - 4 * day, pos: 600, dur: 2400)])
        XCTAssertEqual(out.map(\.id), ["tt1:1:2"])
        XCTAssertFalse(out[0].next)
    }

    func testNinetyPercent_isFinished() {
        XCTAssertTrue(plan([rec("tt9", now - day, pos: 3330, dur: 3600, type: "movie")]).isEmpty)
        XCTAssertEqual(plan([rec("tt9", now - day, pos: 3060, dur: 3600, type: "movie")]).count, 1)
        XCTAssertTrue(ProgressStore.ended(3330, 3600))
        XCTAssertFalse(ProgressStore.ended(3060, 3600))
    }

    func testRemoved_staysOffUntilAnotherIsFinished() {
        let done = rec("tt1:1:1", now - 5 * day, done: true)
        var gone = ProgressRec(type: ContinueNext.nextupType, id: "tt1"); gone.dismissed = true; gone.at = now - 4 * day
        XCTAssertTrue(plan([done, gone], ["tt1": ans(done.at, ep("tt1:1:2", 1, 2, rel: -10))]).isEmpty)
        let later = rec("tt1:1:2", now - day, done: true)
        XCTAssertEqual(plan([done, later, gone], ["tt1": ans(later.at, ep("tt1:1:3", 1, 3, rel: -10))]).map(\.id), ["tt1:1:3"])
    }

    func testNotOutYet_onlyWithTheSetting_andANewSeasonInItsLastWeek() {
        let done = rec("tt1:1:3", now - day, done: true)
        let soon = ["tt1": ans(done.at, ep("tt1:1:4", 1, 4, rel: 3))]
        XCTAssertTrue(plan([done], soon).isEmpty)
        XCTAssertGreaterThan(plan([done], soon, unaired: true).first?.airs ?? 0, now)
        XCTAssertTrue(plan([done], ["tt1": ans(done.at, ep("tt1:2:1", 2, 1, rel: 30), same: false)], unaired: true).isEmpty)
        XCTAssertEqual(plan([done], ["tt1": ans(done.at, ep("tt1:2:1", 2, 1, rel: 3), same: false)], unaired: true).count, 1)
    }

    func testSwitchedOff_nothingAsked() {
        var wanted: [String] = []
        XCTAssertTrue(plan([rec("tt1:1:1", now - day, done: true)], nextOn: false, wanted: &wanted).isEmpty)
        XCTAssertTrue(wanted.isEmpty)
    }

    func testAnswerFromTheEpisodeList() {
        let vids = (1...3).map { (n: Int) in Episode(id: "tt1:1:\(n)", season: 1, episode: n, name: "E\(n)", overview: nil, thumbnail: nil, released: nil) }
        let done = rec("tt1:1:1", now - day, done: true)
        let s = ContinueNext.Show(id: "tt1", type: "series", sig: done.at, last: done, seedAt: done.at)
        let a = ContinueNext.answer(show: s, name: "Show", poster: nil, back: nil, videos: vids, all: ["series:tt1:1:1": done], now: now)
        XCTAssertEqual(a.ep?.id, "tt1:1:2")
        XCTAssertTrue(a.same)
    }

    func testFinishedRecordKeepsItsName_andTheAnswersRoundTrip() {
        let p = ProgressStore(store: tempStore())
        var r = ProgressRec(type: "series", id: "tt1:1:1"); r.name = "Show"; r.addonUrl = "u"; r.pos = 2300; r.dur = 2400
        p.note(r)
        let got = p.get("series", "tt1:1:1")
        XCTAssertEqual(got?.done, true)
        XCTAssertEqual(got?.name, "Show")
        let store = tempStore()
        let n = NextUpAnswers(store: store)
        n.put(["tt1": ans(5, ep("tt1:1:2", 1, 2, rel: -1))])
        XCTAssertEqual(NextUpAnswers(store: store).get("tt1")?.ep?.id, "tt1:1:2")
    }

    func testAdvisory_ratingLeadsTheRows_andTheRegion() {
        let a = Advisory.parse(["items": [["k": "violence", "s": "severe"], ["k": "bogus", "s": "mild"]], "cert": "UA"])
        XCTAssertEqual(a.rows.map { $0.kind + " " + $0.level }, ["Rated UA", "Violence Severe"])
        XCTAssertEqual(Advisory.parse(["items": []]).rows.count, 0)
        XCTAssertEqual(Advisory.region(timeZone: "Asia/Kolkata", locale: "en_US"), "IN")
        XCTAssertEqual(Advisory.region(timeZone: "America/Los_Angeles", locale: ""), "US")
        XCTAssertEqual(Advisory.region(timeZone: "Australia/Perth", locale: "en_GB"), "AU")
        XCTAssertEqual(Advisory.region(timeZone: "Europe/Monaco", locale: "fr_FR"), "FR")
        XCTAssertEqual(Advisory.region(timeZone: "UTC", locale: "en"), "US")
    }
}
