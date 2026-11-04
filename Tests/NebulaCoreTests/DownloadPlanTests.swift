import XCTest
@testable import NebulaCore

/// Downloads' rules (DownloadPlan.swift) — the Android app's DownloadPlanTest cases, plus the playlist refusal.
final class DownloadPlanTests: XCTestCase {
    func testSavable() {
        XCTAssertTrue(DownloadPlan.savable("https://h.example/film.mkv"))
        XCTAssertFalse(DownloadPlan.savable("https://h.example/live.mpd"))
        XCTAssertFalse(DownloadPlan.savable("magnet:?xt=urn:btih:abc"))
        XCTAssertFalse(DownloadPlan.savable("https://h.example/page", embedPage: true))
    }
    func testSniff() {
        XCTAssertEqual(DownloadPlan.sniff(code: 206, contentType: "video/x-matroska", head: "\u{1A}E", total: 2_000_000_000), .file(2_000_000_000))
        XCTAssertEqual(DownloadPlan.sniff(code: 200, contentType: "application/vnd.apple.mpegurl", head: "#EXTM3U", total: 300), .playlist)
        XCTAssertEqual(DownloadPlan.sniff(code: 200, contentType: "text/html", head: "<!doctype html>", total: 500), .refused(DownloadPlan.noPage))
        XCTAssertEqual(DownloadPlan.sniff(code: 200, contentType: "video/mp4", head: "....", total: 0), .refused(DownloadPlan.noLive))
        XCTAssertEqual(DownloadPlan.sniff(code: 206, contentType: "video/mp4", head: "....", total: 5_000_000), .refused(DownloadPlan.notReady))
        XCTAssertEqual(DownloadPlan.sniff(code: 403, contentType: nil, head: "", total: 0), .refused(DownloadPlan.noReach))
        XCTAssertEqual(DownloadPlan.sniff(code: 200, contentType: "application/dash+xml", head: "<MPD", total: 900), .refused(DownloadPlan.noKind))
    }
    func testTotalAndRoom() {
        XCTAssertEqual(DownloadPlan.total(code: 206, contentRange: "bytes 0-4095/123456789", contentLength: "4096"), 123456789)
        XCTAssertEqual(DownloadPlan.total(code: 200, contentRange: nil, contentLength: "777"), 777)
        XCTAssertEqual(DownloadPlan.total(code: 206, contentRange: nil, contentLength: "4096"), 0)
        XCTAssertTrue(DownloadPlan.hasRoom(size: 1 << 30, free: (1 << 30) + DownloadPlan.marginBytes))
        XCTAssertFalse(DownloadPlan.hasRoom(size: 1 << 30, free: 1 << 30))
    }
    func testLines() {
        XCTAssertEqual(DownloadPlan.line(.done, bytes: 1_288_490_189, total: 0), "1.2 GB")
        XCTAssertEqual(DownloadPlan.line(.running, bytes: 536_870_912, total: 1_073_741_824), "50% · 512 MB of 1.0 GB")
        XCTAssertEqual(DownloadPlan.line(.paused, bytes: 268_435_456, total: 1_073_741_824), "Paused · 25%")
        XCTAssertEqual(DownloadPlan.line(.queued, bytes: 0, total: 0), "Waiting to start")
    }
    func testShelves() {
        struct R { let name: String; let type: String; let id: String; let at: Double }
        let rows = [
            R(name: "The Bear · S1E2 · Hands", type: "series", id: "tt1:1:2", at: 3),
            R(name: "Arrival", type: "movie", id: "tt2", at: 4),
            R(name: "The Bear · S1E1 · System", type: "series", id: "tt1:1:1", at: 1),
            R(name: "The Bear · S0E1 · Special", type: "series", id: "tt1:0:1", at: 5),
        ]
        let sh = DownloadPlan.shelves(rows, name: { $0.name }, type: { $0.type }, id: { $0.id }, at: { $0.at })
        XCTAssertEqual(sh.map(\.title), ["The Bear", "Arrival"])
        XCTAssertEqual(sh[0].rows.map(\.id), ["tt1:1:1", "tt1:1:2", "tt1:0:1"])
        XCTAssertEqual(DownloadPlan.numbers("The Bear · S2E10 · Fishes")?.season, 2)
        XCTAssertEqual(DownloadPlan.numbers("The Bear · S2E10 · Fishes")?.episode, 10)
        XCTAssertNil(DownloadPlan.nameParts("Arrival").rest)
    }
}
