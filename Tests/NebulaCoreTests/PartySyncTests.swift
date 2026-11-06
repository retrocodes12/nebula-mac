import XCTest
@testable import NebulaCore

/// The watch party's rules: the same cases as Android's PartySyncTest and the shared player's rig.
final class PartySyncTests: XCTestCase {
    private func st(_ playing: Bool, _ pos: Double, _ at: Int64, rate: Double = 1, name: String = "Ana", waiting: Bool = false) -> PartyState {
        PartyState(playing: playing, pos: pos, rate: rate, waiting: waiting, at: at, seq: 1, by: "x", name: name)
    }

    func testExpect() {
        XCTAssertEqual(PartySync.expect(st(true, 10, 1_000), now: 11_000), 20, accuracy: 1e-9)
        XCTAssertEqual(PartySync.expect(st(true, 10, 1_000, rate: 1.5), now: 11_000), 25, accuracy: 1e-9)
        XCTAssertEqual(PartySync.expect(st(false, 10, 1_000), now: 99_000), 10, accuracy: 1e-9)
        XCTAssertEqual(PartySync.expect(st(true, 10, 5_000), now: 1_000), 10, accuracy: 1e-9)
    }

    func testMove() {
        XCTAssertEqual(PartySync.move(err: 2, rate: 1, nudging: false), .seek(by: 2, rate: 1))
        XCTAssertEqual(PartySync.move(err: 0.5, rate: 1, nudging: false), .nudge(1.05))
        XCTAssertEqual(PartySync.move(err: -0.5, rate: 1, nudging: false), .nudge(0.95))
        XCTAssertEqual(PartySync.move(err: 0.2, rate: 1, nudging: false), .hold(1))
        XCTAssertEqual(PartySync.move(err: 0.2, rate: 1, nudging: true), .nudge(1.05))
        XCTAssertTrue(PartySync.isNudge(1.575, of: 1.5))
        XCTAssertFalse(PartySync.isNudge(1.25, of: 1))
    }

    func testClock() {
        var c = PartySync.Clock()
        c.sample(sentAt: 1_000, server: 50_000, now: 1_200)
        XCTAssertEqual(c.off, 48_900)
        c.sample(sentAt: 2_000, server: 51_000, now: 2_050)
        XCTAssertEqual(c.off, 48_975)
        c.sample(sentAt: 3_000, server: 60_000, now: 3_900)
        XCTAssertEqual(c.off, 48_975)
    }

    func testNotice() {
        let prev = st(true, 100, 10_000, name: "Host")
        XCTAssertEqual(PartySync.notice(prev, st(false, 101, 11_000)), "Ana paused")
        XCTAssertEqual(PartySync.notice(st(false, 101, 11_000), st(true, 101, 12_000)), "Ana resumed")
        XCTAssertEqual(PartySync.notice(prev, st(true, 101, 11_000, rate: 1.5)), "Ana changed the speed to 1.5×")
        XCTAssertEqual(PartySync.notice(prev, st(true, 3730, 11_000)), "Ana skipped to 1:02:10")
        XCTAssertNil(PartySync.notice(prev, st(true, 101.2, 11_000)))
        XCTAssertNil(PartySync.notice(prev, st(false, 101, 11_000, waiting: true)))
    }

    func testLabelsKeysWaiters() {
        XCTAssertEqual(PartySync.gapLabel(40.2), "40 s")
        XCTAssertEqual(PartySync.gapLabel(170), "3 min")
        XCTAssertEqual(PartySync.gapLabel(3900), "1 h 5 min")
        XCTAssertEqual(PartySync.behindReported(1), 5)
        XCTAssertEqual(PartySync.behindReported(124), 125)
        XCTAssertEqual(PartySync.keyOf("movie", "tt1", "https://x"), "movie:tt1")
        XCTAssertEqual(PartySync.keyOf(nil, nil, "https://x"), "https://x")
        XCTAssertTrue(PartySync.sameShow("series", "tt5:1:2", "series", "tt5:1:3"))
        XCTAssertTrue(PartySync.sameShow("series", "kitsu:9:4", "series", "kitsu:9:5"))
        XCTAssertFalse(PartySync.sameShow("movie", "tt1", "movie", "tt2"))
        let ms = [PartyMember(id: "me", name: "Me", host: true, s: "ready", k: "movie:tt1"),
                  PartyMember(id: "a", name: "Ana", host: false, s: "buffering", k: "movie:tt1"),
                  PartyMember(id: "b", name: "Bo", host: false, s: "loading", k: "movie:tt2"),
                  PartyMember(id: "c", name: "Cy", host: false, s: "loading", k: "movie:tt1")]
        XCTAssertEqual(PartySync.waiters(ms, me: "me", key: "movie:tt1", ignore: []).map(\.name), ["Ana", "Cy"])
        XCTAssertEqual(PartySync.waiters(ms, me: "me", key: "movie:tt1", ignore: ["c"]).map(\.name), ["Ana"])
    }

    func testWireAndMatch() {
        let d = PartyStreamDesc(url: "https://h/a.m3u8", title: "A", type: "movie", id: "tt1", file: "Sintel.2010.1080p.WEB.x264-RIG.mkv", share: false)
        let w = d.wire()
        XCTAssertNil(w["url"])
        XCTAssertEqual(w["share"] as? Bool, false)
        let back = PartyStreamDesc.from(w)
        XCTAssertEqual(back?.url, "")
        XCTAssertEqual(back?.share, false)
        XCTAssertNil(PartyStreamDesc.from(["title": "x", "url": "file:///etc/passwd"]))
        var b = StreamItem(name: "B", title: "x", url: "https://b"); b.fileName = "Sintel.2010.1080p.WEB.x264-RIG.mkv"
        let a = StreamItem(name: "A", title: "Other.Film.2010.720p.WEB.x264-X.mkv", url: "https://a")
        XCTAssertEqual(PartySync.matchOwn([a, b], file: "Sintel.2010.1080p.WEB.x264-RIG.mkv")?.url, "https://b")
        XCTAssertNil(PartySync.matchOwn([a, b], file: "Nothing.Here.2001.mkv"))
    }
}
