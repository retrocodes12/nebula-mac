import XCTest
import Foundation
@testable import NebulaCore

/// The profile PIN (10-23): the hash every app shares, the lock in the synced list, and the cloud's password check.
final class PinTests: XCTestCase {
    private func store() -> Store {
        Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-test-" + UUID().uuidString))
    }

    func testTheHashMatchesTheOtherApps() {
        XCTAssertEqual(pinHash("0a1b2c3d", "1234"), "10100505")
        XCTAssertEqual(pinHash("ffffffff", "0000"), "11ce4385")
        XCTAssertEqual(pinHash("00000000", "9999"), "e4f71e45")
    }

    func testALockKnowsItsPinAndOnlyThat() {
        let k = PinLock.make(pin: "4821")!
        XCTAssertEqual(k.s.count, 8)
        XCTAssertNotNil(PinLock(s: k.s, h: k.h))
        XCTAssertTrue(k.matches("4821"))
        XCTAssertFalse(k.matches("4822"))
        XCTAssertFalse(k.matches("482"))
        XCTAssertNil(PinLock.make(pin: "12a4"))
        XCTAssertNil(PinLock.make(pin: "12345"))
        // only 8 lowercase hex digits make a lock
        XCTAssertNil(PinLock(s: "0A1B2C3D", h: "10100505"))
        XCTAssertNil(PinLock(s: "0a1b2c3", h: "10100505"))
        XCTAssertNil(PinLock(["s": "0a1b2c3d"] as JSONObject))
        XCTAssertEqual(PinLock(["s": "0a1b2c3d", "h": "10100505"] as JSONObject)?.matches("1234"), true)
    }

    func testTheLockRoundTripsThroughTheList() {
        let s = store(), v = Viewers(store: s)
        let k = PinLock(s: "0a1b2c3d", h: "10100505")!
        v.setList([Viewer(id: "a", name: "", av: ""), Viewer(id: "b", name: "Kids", av: "#0A84FF", lock: k)])
        let wire = v.doc().arr("list").compactMap { $0 as? JSONObject }
        XCTAssertEqual(wire.first { $0.str("id") == "b" }?.obj("lock")?.str("h"), "10100505")
        XCTAssertNil(wire.first { $0.str("id") == "a" }?["lock"], "no lock, no field")
        XCTAssertEqual(v.list().first { $0.id == "b" }?.lock, k)
        XCTAssertNil(v.list().first { $0.id == "a" }?.lock)
        // the text form the cloud carries, back again
        let back = JSON.object(JSON.text(v.doc())) ?? [:]
        XCTAssertEqual(Viewers.parse(back).first { $0.id == "b" }?.lock, k)
        // an edit that keeps the profile keeps its lock
        v.setList(v.list().map { Viewer(id: $0.id, name: $0.name + "!", av: $0.av, lock: $0.lock) })
        XCTAssertEqual(v.list().first { $0.id == "b" }?.lock, k)
        // a lock from another device arrives with the list
        let remote: JSONObject = ["at": nowMs() + 10_000,
                                  "list": [["id": "a", "name": "", "av": "", "lock": ["s": "ffffffff", "h": "11ce4385"] as JSONObject] as JSONObject] as [Any]]
        XCTAssertTrue(v.merge(remote).changed)
        XCTAssertEqual(v.list().first { $0.id == "a" }?.lock?.matches("0000"), true)
        // a broken one is no lock
        let bad: JSONObject = ["at": nowMs() + 20_000, "list": [["id": "a", "lock": ["s": "zz", "h": "11ce4385"] as JSONObject] as JSONObject] as [Any]]
        XCTAssertTrue(v.merge(bad).changed)
        XCTAssertNil(v.list().first?.lock)
    }

    func testForgotPinAsksTheCloudForThePassword() async {
        let server = FakeCloud()
        let s = store()
        server.tokens.insert("tok0")
        s.setObject("cloud_link", ["gid": "g1", "token": "tok0"])
        let cloud = Cloud(store: s, addons: AddonStore(store: s), progress: ProgressStore(store: s), library: LibraryStore(store: s),
                          transport: server, base: "https://c.test/cloud")
        let ok = await cloud.checkPassword("correct horse")
        XCTAssertNil(ok)
        let wrong = await cloud.checkPassword("nope")
        XCTAssertEqual(wrong, "Wrong password.")
        let busy = await cloud.checkPassword("too fast")
        XCTAssertEqual(busy, "Too many tries — wait a minute.")
        XCTAssertTrue(server.log.contains("POST /v1/profile/check"))
        server.tokens.removeAll()
        let gone = await cloud.checkPassword("correct horse")
        XCTAssertEqual(gone, "Could not reach Nebula. Try again.")
    }
}
