import XCTest
import Foundation
@testable import NebulaCore

/// Autoplay's rules (Autoplay.swift; Android's AutoplayTest, the shared player's shelf mode): the best row, when to stop
/// waiting, a debrid clip.
final class AutoplayTests: XCTestCase {
    private let comet = Addon(manifestUrl: "https://comet.example/manifest.json", name: "Comet | TB", base: "https://comet.example")
    private let plain = Addon(manifestUrl: "https://plain.example/manifest.json", name: "Plain", base: "https://plain.example")
    private func row(_ name: String, title: String = "", url: String? = nil, a: Addon? = nil) -> Autoplay.Row {
        Autoplay.Row(StreamItem(name: name, title: title, url: url ?? "https://h.example/" + name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!), a ?? plain)
    }
    private func names(_ rows: [Autoplay.Row]) -> [String] { rows.map(\.stream.name) }
    private func s(_ name: String) -> StreamItem { StreamItem(name: name, title: "", url: "u") }

    func testDebridMarksReadyWaitAndButtons() {
        XCTAssertEqual(Autoplay.debrid(name: "[TB⚡] Comet 2160p", url: ""), .ready)
        XCTAssertEqual(Autoplay.debrid(name: "[RD+] Torrentio 1080p", url: ""), .ready)
        XCTAssertEqual(Autoplay.debrid(name: "[TB⬇️] Comet 2160p", url: ""), .wait)
        XCTAssertEqual(Autoplay.debrid(name: "[TB download] Torrentio", url: ""), .wait)
        XCTAssertEqual(Autoplay.debrid(name: "[TB🔄] Comet Sync", url: ""), .action)
        XCTAssertEqual(Autoplay.debrid(name: "Comet", url: "https://x.example/debrid-sync/abc"), .action)
        XCTAssertEqual(Autoplay.debrid(name: "Torrentio 4K", url: ""), .none)
    }

    func testInstantNamedServiceBeforeOthers() {
        XCTAssertEqual(Autoplay.instant(s("[TB⚡] Comet 1080p")), 2)
        XCTAssertEqual(Autoplay.instant(s("[RD⚡] Comet 1080p")), 1)
        XCTAssertEqual(Autoplay.instant(s("[TB⬇️] Comet 1080p")), 0)
        XCTAssertEqual(Autoplay.instant(s("Plain 4K")), 0)
    }

    func testDebridAddonNames() {
        XCTAssertTrue(Autoplay.debridAddon("Comet | ElfHosted | TB"))
        XCTAssertTrue(Autoplay.debridAddon("Torrentio RD"))
        XCTAssertTrue(Autoplay.debridAddon("TorBox Search"))
        XCTAssertFalse(Autoplay.debridAddon("Cinemeta"))
        XCTAssertFalse(Autoplay.debridAddon("TBS Sports"))
    }

    func testRankDropsHeldAndButtonsThenInstantThenQuality() {
        let rows = [row("Plain 4K"), row("[TB⬇️] Comet 4K", a: comet), row("[TB🔄] Comet Sync", a: comet),
                    row("[RD⚡] Other 1080p"), row("[TB⚡] Comet 1080p", a: comet), row("Plain 720p")]
        XCTAssertEqual(names(Autoplay.rank(rows, Autoplay.Cfg())), ["[TB⚡] Comet 1080p", "[RD⚡] Other 1080p", "Plain 4K", "Plain 720p"])
    }

    func testRankInstantOffQualityLeads() {
        let rows = [row("[TB⚡] Comet 1080p", a: comet), row("Plain 4K")]
        XCTAssertEqual(names(Autoplay.rank(rows, Autoplay.Cfg(instant: false))), ["Plain 4K", "[TB⚡] Comet 1080p"])
    }

    func testRankAboveAimSitsUnderTheAimButOverLower() {
        let rows = [row("A 4K"), row("B 720p"), row("C 1080p"), row("D")]
        XCTAssertEqual(names(Autoplay.rank(rows, Autoplay.Cfg(max: 3))), ["C 1080p", "A 4K", "B 720p", "D"])
    }

    func testRankSlowThenStutterSinkTiesKeepAddonOrder() {
        let rows = [row("A 1080p"), row("B 1080p AV1"), row("C 1080p"), row("D 1080p")]
        let ranked = Autoplay.rank(rows, Autoplay.Cfg(), slow: { $0.name == "A 1080p" }, stutter: { $0.name == "B 1080p AV1" })
        XCTAssertEqual(names(ranked), ["C 1080p", "D 1080p", "B 1080p AV1", "A 1080p"])
    }

    func testRankKeepWaitingSinksNotReadyRows() {
        let rows = [row("[TB⬇️] Comet 4K", a: comet), row("Plain 720p"), row("[TB🔄] Sync", a: comet)]
        XCTAssertEqual(names(Autoplay.rank(rows, Autoplay.Cfg(), keepWaiting: true)), ["Plain 720p", "[TB⬇️] Comet 4K"])
    }

    private var ready4k: StreamItem { s("[TB⚡] Comet 2160p") }
    private var ready1080: StreamItem { s("[TB⚡] Comet 1080p") }
    private var plain1080: StreamItem { s("Plain 1080p") }
    private var plain4k: StreamItem { s("Plain 4K") }

    func testVerdictQuick() {
        let q = Autoplay.Cfg(wait: "quick")
        XCTAssertEqual(Autoplay.verdict(q, elapsedMs: 1_000, best: ready1080, asking: ["Slow"], allAnswered: false), .pick)
        XCTAssertEqual(Autoplay.verdict(q, elapsedMs: 1_000, best: plain4k, asking: ["Slow"], allAnswered: false), .pick)
        XCTAssertEqual(Autoplay.verdict(q, elapsedMs: 7_000, best: plain1080, asking: ["Slow"], allAnswered: false), .wait)
        XCTAssertEqual(Autoplay.verdict(q, elapsedMs: 8_000, best: plain1080, asking: ["Slow"], allAnswered: false), .pick)
    }

    func testVerdictBalanced() {
        let b = Autoplay.Cfg()
        XCTAssertEqual(Autoplay.verdict(b, elapsedMs: 1_000, best: ready4k, asking: ["Comet | TB"], allAnswered: false), .pick)
        // instant but under the aim, a debrid add-on still asked: wait for its 4K
        XCTAssertEqual(Autoplay.verdict(b, elapsedMs: 1_000, best: ready1080, asking: ["Comet | TB"], allAnswered: false), .wait)
        // …no debrid add-on left: the instant row goes
        XCTAssertEqual(Autoplay.verdict(b, elapsedMs: 1_000, best: ready1080, asking: ["Cinemeta"], allAnswered: false), .pick)
        XCTAssertEqual(Autoplay.verdict(b, elapsedMs: 10_000, best: plain4k, asking: ["Cinemeta"], allAnswered: false), .wait)
        XCTAssertEqual(Autoplay.verdict(b, elapsedMs: 25_000, best: plain1080, asking: ["Cinemeta"], allAnswered: false), .pick)
        XCTAssertEqual(Autoplay.verdict(b, elapsedMs: 60_000, best: nil, asking: ["Cinemeta"], allAnswered: false), .wait)
        XCTAssertEqual(Autoplay.verdict(b, elapsedMs: 90_000, best: nil, asking: ["Cinemeta"], allAnswered: false), .none)
    }

    func testVerdictAllAndEveryoneAnswered() {
        let all = Autoplay.Cfg(wait: "all")
        XCTAssertEqual(Autoplay.verdict(all, elapsedMs: 60_000, best: ready4k, asking: ["Slow"], allAnswered: false), .wait)
        XCTAssertEqual(Autoplay.verdict(all, elapsedMs: 90_000, best: ready4k, asking: ["Slow"], allAnswered: false), .pick)
        XCTAssertEqual(Autoplay.verdict(all, elapsedMs: 3_000, best: plain1080, asking: [], allAnswered: true), .settle)
        XCTAssertEqual(Autoplay.verdict(Autoplay.Cfg(), elapsedMs: 3_000, best: nil, asking: [], allAnswered: true), .none)
    }

    func testBriefClipOnlyADebridFilmUnderThirtySeconds() {
        XCTAssertTrue(Autoplay.briefClip(name: "[TB⚡] Comet 2160p", url: "u", type: "movie", durationMs: 8_000))
        XCTAssertTrue(Autoplay.briefClip(name: "[TB⬇️] Comet 2160p", url: "u", type: "series", durationMs: 8_000))
        XCTAssertFalse(Autoplay.briefClip(name: "[TB⚡] Comet 2160p", url: "u", type: "movie", durationMs: 7_200_000))
        XCTAssertFalse(Autoplay.briefClip(name: "Plain trailer", url: "u", type: "movie", durationMs: 8_000))
        XCTAssertFalse(Autoplay.briefClip(name: "[TB⚡] Comet", url: "u", type: "tv", durationMs: 8_000))
        XCTAssertFalse(Autoplay.briefClip(name: "[TB⚡] Comet", url: "u", type: "movie", durationMs: 0))
    }

    func testNextSkipsTheFailedAndTheCurrent() {
        let q = [row("A", url: "a"), row("B", url: "b"), row("C", url: "c")]
        XCTAssertEqual(Autoplay.next(q, cur: "a", failed: ["b"])?.stream.url, "c")
        XCTAssertNil(Autoplay.next(q, cur: "c", failed: ["a", "b"]))
    }

    func testCardLines() {
        XCTAssertEqual(Autoplay.startLine(ready4k, addonName: "Comet | TB"), "Starting 4K · Comet | TB · instant")
        XCTAssertEqual(Autoplay.startLine(plain1080, addonName: "Plain", why: "error"), "That one didn\u{2019}t play · trying 1080p · Plain")
        XCTAssertEqual(Autoplay.startLine(plain1080, addonName: "Plain", why: "slow"), "That one was slow to start · trying 1080p · Plain")
        XCTAssertEqual(Autoplay.startLine(plain1080, addonName: "Plain", why: "brief"), "That one wasn\u{2019}t ready · trying 1080p · Plain")
        XCTAssertEqual(Autoplay.askLine(found: 0, asking: ["A", "B"]), "Asking A and B for streams…")
        XCTAssertEqual(Autoplay.askLine(found: 3, asking: ["A", "B", "C"]), "Found 3 streams · still asking 3 add-ons")
        XCTAssertEqual(Autoplay.askLine(found: 1, asking: []), "Found 1 stream · picking the best")
        XCTAssertEqual(Autoplay.askLine(found: 0, asking: []), "Finding the best stream…")
    }

    func testMenuBestFirstWithLookAlikesFailuresAndNotReady() {
        let rows = [row("Plain 1080p", url: "https://a.example/1"), row("Plain 1080p", url: "https://www.b.example/2"),
                    row("[TB⬇️] Comet 4K", title: "💾 4.2 GB", url: "https://c.example/3", a: comet),
                    row("[TB⚡] Comet 4K", url: "https://c.example/4", a: comet)]
        let m = Autoplay.menu(cur: "https://c.example/4", cfg: Autoplay.Cfg(), rows: rows, failed: ["https://a.example/1"])
        XCTAssertEqual(m.map(\.label), ["4K · Comet | TB · Instant", "1080p · Plain · a.example — did not play",
                                        "1080p · Plain · b.example", "4K · Comet | TB · 4.2 GB — not ready yet"])
        XCTAssertEqual(m.first?.url, "https://c.example/4")
    }

    func testPrefsDefaultsAndBadValues() {
        let p = Prefs(store: Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-test-" + UUID().uuidString)))
        XCTAssertFalse(p.bestPlay)
        XCTAssertEqual(p.autoplay, Autoplay.Cfg())
        p.bestPlay = true; p.apMax = 1080; p.apInstant = false; p.apWait = "quick"; p.apRetry = 3; p.apStart = 20; p.apBack = "list"
        XCTAssertTrue(p.bestPlay)
        XCTAssertEqual(p.autoplay, Autoplay.Cfg(max: 3, instant: false, wait: "quick", retry: 3, startS: 20, back: "list"))
        p.apMax = 999; p.apWait = "soon"; p.apRetry = 7; p.apStart = 5; p.apBack = "home"
        XCTAssertEqual(p.autoplay, Autoplay.Cfg(max: 4, instant: false, wait: "balanced", retry: 5, startS: 45, back: "title"))
        p.apMax = 720
        XCTAssertEqual(p.autoplay.max, 2)
    }
}
