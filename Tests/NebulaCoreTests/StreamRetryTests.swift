import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NebulaCore

/// A streams request that failed is asked once more (2026-10-29): which failures, how many asks, and what comes back.
final class StreamRetryTests: XCTestCase {
    /// Answers in turn: an HTTP code with a body, or an error thrown.
    actor Script: Transport {
        enum Step { case code(Int, String), fail(Error) }
        var steps: [Step]
        var asked = 0
        init(_ steps: [Step]) { self.steps = steps }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            asked += 1
            switch steps.isEmpty ? .code(500, "") : steps.removeFirst() {
            case .code(let c, let b): return (Data(b.utf8), c)
            case .fail(let e): throw e
            }
        }
    }

    let ok = #"{"streams":[{"name":"A 1080p","url":"https://h.test/a.mkv"}]}"#

    func testTheRule() {
        XCTAssertTrue(Stremio.worthAskingAgain(HTTPFailure(code: 500, error: "")))
        XCTAssertTrue(Stremio.worthAskingAgain(HTTPFailure(code: 503, error: "")))
        XCTAssertTrue(Stremio.worthAskingAgain(HTTPFailure(code: 408, error: "")))
        XCTAssertTrue(Stremio.worthAskingAgain(HTTPFailure(code: 429, error: "")))
        XCTAssertTrue(Stremio.worthAskingAgain(HTTPFailure(code: 0, error: "")))
        XCTAssertTrue(Stremio.worthAskingAgain(URLError(.timedOut)))
        XCTAssertTrue(Stremio.worthAskingAgain(URLError(.networkConnectionLost)))
        XCTAssertTrue(Stremio.worthAskingAgain(URLError(.notConnectedToInternet)))
        XCTAssertFalse(Stremio.worthAskingAgain(HTTPFailure(code: 404, error: "")))
        XCTAssertFalse(Stremio.worthAskingAgain(HTTPFailure(code: 403, error: "")))
        XCTAssertFalse(Stremio.worthAskingAgain(HTTPFailure(code: 400, error: "")))
        XCTAssertFalse(Stremio.worthAskingAgain(URLError(.cancelled)))
        XCTAssertFalse(Stremio.worthAskingAgain(CancellationError()))
        XCTAssertFalse(Stremio.worthAskingAgain(Stremio.BadJSON()))
    }

    func testAServerErrorIsAskedOnceMoreAndItsAnswerKept() async throws {
        let t = Script([.code(503, ""), .code(200, ok)])
        let s = try await Stremio(transport: t).loadStreamsAskingTwice(base: "https://x.test", type: "movie", id: "tt1", pause: 1_000_000)
        XCTAssertEqual(s.map(\.name), ["A 1080p"])
        let n = await t.asked
        XCTAssertEqual(n, 2)
    }

    func testANetworkErrorIsAskedOnceMore() async throws {
        let t = Script([.fail(URLError(.timedOut)), .code(200, ok)])
        let s = try await Stremio(transport: t).loadStreamsAskingTwice(base: "https://x.test", type: "movie", id: "tt1", pause: 1_000_000)
        XCTAssertEqual(s.count, 1)
        let n = await t.asked
        XCTAssertEqual(n, 2)
    }

    func testOnlyOnceMore() async {
        let t = Script([.code(500, ""), .code(502, ""), .code(200, ok)])
        do {
            _ = try await Stremio(transport: t).loadStreamsAskingTwice(base: "https://x.test", type: "movie", id: "tt1", pause: 1_000_000)
            XCTFail("a second failure is final")
        } catch {
            XCTAssertEqual((error as? HTTPFailure)?.code, 502)
        }
        let n = await t.asked
        XCTAssertEqual(n, 2)
    }

    func testANotFoundIsFinalAtOnce() async {
        let t = Script([.code(404, ""), .code(200, ok)])
        do {
            _ = try await Stremio(transport: t).loadStreamsAskingTwice(base: "https://x.test", type: "movie", id: "tt1", pause: 1_000_000)
            XCTFail("a 404 is the add-on's answer")
        } catch {
            XCTAssertEqual((error as? HTTPFailure)?.code, 404)
        }
        let n = await t.asked
        XCTAssertEqual(n, 1)
    }

    func testTheDefaultPauseIsTwoSeconds() async throws {
        let t = Script([.code(500, ""), .code(200, ok)])
        let at = Date()
        _ = try await Stremio(transport: t).loadStreamsAskingTwice(base: "https://x.test", type: "movie", id: "tt1")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(at), 1.9)
    }
}
