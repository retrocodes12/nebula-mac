import XCTest
import Foundation
@testable import NebulaCore

/// Who's watching: the list as the other apps write it, where each profile's history lives, and the merge.
final class ViewersTests: XCTestCase {
    private func store() -> Store {
        Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-test-" + UUID().uuidString))
    }

    func testParseKeepsTheFirstAndAtMostTwo() {
        XCTAssertEqual(Viewers.parse([:]).map(\.id), ["a"])
        let d: JSONObject = ["at": 1, "list": [["id": "b", "name": "Kids"], ["id": "c", "name": "X"], ["id": "b", "name": "Dup"]] as [Any]]
        XCTAssertEqual(Viewers.parse(d).map(\.id), ["a", "b"])
        XCTAssertEqual(Viewers.parse(d).first { $0.id == "b" }?.name, "Kids")
    }

    func testOnlyHistoryMovesForTheSecondProfile() {
        XCTAssertEqual(Viewers.key("progress", viewer: "a"), "progress")
        XCTAssertEqual(Viewers.key("progress", viewer: "b"), "progress_b")
        XCTAssertEqual(Viewers.key("library", viewer: "b"), "library_b")
        XCTAssertEqual(Viewers.key("addons", viewer: "b"), "addons")
        XCTAssertEqual(Viewers.key("viewers", viewer: "b"), "viewers")
    }

    func testEachProfileReadsAndWritesItsOwnHistory() {
        let s = store(), v = Viewers(store: s), p = ProgressStore(store: s)
        p.viewers = v
        p.mutate { m in m["movie:tt1"] = ProgressRec(type: "movie", id: "tt1"); return true }
        v.setCurrent("b"); p.reset()
        XCTAssertTrue(p.all().isEmpty, "the second profile starts empty")
        p.mutate { m in m["movie:tt2"] = ProgressRec(type: "movie", id: "tt2"); return true }
        XCTAssertNotNil(s.object("progress_b").obj("movie:tt2"))
        XCTAssertNil(s.object("progress").obj("movie:tt2"))
        v.setCurrent("a"); p.reset()
        XCTAssertNotNil(p.all()["movie:tt1"])
        XCTAssertNil(p.all()["movie:tt2"])
    }

    func testMergeNewestWinsAndARemovalMovesTheDeviceBack() {
        let s = store(), v = Viewers(store: s)
        v.setList([Viewer(id: "a", name: "", av: ""), Viewer(id: "b", name: "Kids", av: "")])
        v.setCurrent("b")
        let older: JSONObject = ["at": 1, "list": [["id": "a", "name": ""]] as [Any]]
        XCTAssertEqual(v.merge(older).localNewer, true)
        XCTAssertEqual(v.list().count, 2)
        let newer: JSONObject = ["at": nowMs() + 10_000, "list": [["id": "a", "name": ""]] as [Any]]
        XCTAssertEqual(v.merge(newer).changed, true)
        XCTAssertEqual(v.list().count, 1)
        XCTAssertEqual(v.current, "a")
    }
}
