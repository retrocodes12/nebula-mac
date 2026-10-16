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

    func testHistoryAndAddonsMoveForTheSecondProfile() {
        XCTAssertEqual(Viewers.key("progress", viewer: "a"), "progress")
        XCTAssertEqual(Viewers.key("progress", viewer: "b"), "progress_b")
        XCTAssertEqual(Viewers.key("library", viewer: "b"), "library_b")
        XCTAssertEqual(Viewers.key("addons", viewer: "a"), "addons")
        XCTAssertEqual(Viewers.key("addons", viewer: "b"), "addons_b")
        XCTAssertEqual(Viewers.key("addons_sync", viewer: "b"), "addons_sync_b")
        XCTAssertEqual(Viewers.key("viewers", viewer: "b"), "viewers")
        XCTAssertEqual(Viewers.key("sub_style", viewer: "b"), "sub_style")
    }

    func testTheSecondProfileStartsAsACopyOfTheFirstsAddons() {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        let x = Addon(manifestUrl: "https://x.example/manifest.json", name: "X", base: "https://x.example")
        let y = Addon(manifestUrl: "https://y.example/manifest.json", name: "Y", base: "https://y.example")
        a.add(x); a.add(y); a.remove(y.manifestUrl); a.add(y); a.move(y.manifestUrl, by: -1)
        let firstSync = s.object("addons_sync")
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [y.manifestUrl, x.manifestUrl], "a copy, in the first profile's order")
        // the stamps are the first profile's own, not the moment of the copy
        XCTAssertEqual(a.syncDoc().obj("at")?.int64(x.manifestUrl), firstSync.obj("at")?.int64(x.manifestUrl))
        XCTAssertEqual(a.syncDoc().int64("orderAt"), firstSync.int64("orderAt"))
        // from here each keeps its own
        a.remove(x.manifestUrl)
        XCTAssertEqual(a.all().map(\.manifestUrl), [y.manifestUrl])
        XCTAssertNotNil(s.object("addons_sync_b").obj("removed")?[x.manifestUrl])
        v.setCurrent("a")
        XCTAssertEqual(a.all().map(\.manifestUrl), [y.manifestUrl, x.manifestUrl])
        XCTAssertNil(s.object("addons_sync").obj("removed")?[x.manifestUrl])
        // the copy is made once: a list the second profile emptied stays empty
        v.setCurrent("b"); a.remove(y.manifestUrl)
        XCTAssertTrue(a.all().isEmpty)
    }

    func testAnEmptyFirstProfileGivesAnEmptySecond() {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        v.setCurrent("b")
        XCTAssertTrue(a.all().isEmpty)
        XCTAssertNotNil(s.string("addons_b"))
    }

    func testANewerRemovalFromAnotherDeviceBeatsTheCopy() async {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        let x = Addon(manifestUrl: "https://x.example/manifest.json", name: "X", base: "https://x.example")
        a.add(x)
        let added = s.object("addons_sync").obj("at")?.int64(x.manifestUrl) ?? 0
        v.setCurrent("b")
        let cloud = Cloud(store: s, addons: a, progress: ProgressStore(store: s), library: LibraryStore(store: s), viewers: v)
        // another device's second profile removed X after the first profile added it
        let remote: JSONObject = ["list": JSONObject(), "removed": [x.manifestUrl: added + 5_000] as JSONObject, "order": [String](), "orderAt": 0]
        let r = await cloud.merge("addons", remote)
        XCTAssertTrue(r.changed)
        XCTAssertTrue(a.all().isEmpty, "the removal wins over the copy's older stamp")
        v.setCurrent("a")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl], "the first profile keeps it")
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

    // MARK: signed in: the cloud decides the second profile's first list

    private func linkedDevice(_ server: FakeCloud) -> (Store, Viewers, AddonStore, Cloud) {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        server.tokens.insert("tok0")
        s.setObject("cloud_link", ["gid": "g1", "token": "tok0"])
        let cloud = Cloud(store: s, addons: a, progress: ProgressStore(store: s), library: LibraryStore(store: s),
                          transport: server, base: "https://c.test/cloud", viewers: v)
        return (s, v, a, cloud)
    }
    private let x = Addon(manifestUrl: "https://x.example/manifest.json", name: "X", base: "https://x.example")
    private let z = "https://z.example/manifest.json"

    func testTheCloudsOwnSecondProfileListIsTakenAsItIs() async {
        let server = FakeCloud()
        let doc: JSONObject = ["list": [z: ["name": "Z", "base": "https://z.example", "at": 5] as JSONObject] as JSONObject,
                               "removed": [x.manifestUrl: 7] as JSONObject, "order": [z], "orderAt": 6]
        server.kv["addons_b"] = (JSON.text(doc), 3)
        let (s, v, a, cloud) = linkedDevice(server)
        a.add(x)
        s.setObject("cloud_revs", ["addons_b": 3])      // a stale memory of it must not skip the fetch
        await cloud.prepareAddons(for: "b")
        XCTAssertEqual(s.object("addons_b").arr("list").count, 0, "empty, not a copy of the first profile")
        v.setCurrent("b")
        await cloud.pullAll(force: true)
        XCTAssertEqual(a.all().map(\.manifestUrl), [z], "the cloud's list, without the first profile's X")
        XCTAssertNotNil(a.syncDoc().obj("removed")?[x.manifestUrl])
        v.setCurrent("a")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
    }

    func testWithNoCloudCopyTheSecondProfileStartsAsTheFirstsAndGoesUp() async {
        let server = FakeCloud()
        let (s, v, a, cloud) = linkedDevice(server)
        a.add(x)
        let stamp = s.object("addons_sync").obj("at")?.int64(x.manifestUrl) ?? 0
        await cloud.prepareAddons(for: "b")
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
        await cloud.pullAll(force: true)
        let up = JSON.object(server.kv["addons_b"]?.v ?? "") ?? [:]
        XCTAssertEqual(up.obj("list")?.obj(x.manifestUrl)?.int64("at"), stamp, "sent up with the first profile's own stamp")
        XCTAssertNil(server.kv["addons"], "the first profile's copy untouched")
    }

    func testSignedInTheSecondProfileWaitsForTheCloudThenTheLaunchPullDecides() async {
        let server = FakeCloud()
        let doc: JSONObject = ["list": [z: ["name": "Z", "base": "https://z.example", "at": 5] as JSONObject] as JSONObject,
                               "removed": JSONObject(), "order": [z], "orderAt": 6]
        server.kv["addons_b"] = (JSON.text(doc), 1)
        let (s, v, a, cloud) = linkedDevice(server)
        a.add(x)
        v.setCurrent("b")                                 // a device already on the second profile (0.5.x: shared add-ons)
        XCTAssertTrue(a.all().isEmpty)
        XCTAssertNil(s.string("addons_b"), "nothing written before the cloud answers")
        await cloud.pullAll(force: true)
        XCTAssertEqual(a.all().map(\.manifestUrl), [z])
    }

    func testTheCloudNotAnsweringFallsBackToTheCopy() async {
        let server = FakeCloud()
        let (_, v, a, cloud) = linkedDevice(server)
        a.add(x)
        server.tokens.removeAll()                         // every signed call refused
        await cloud.prepareAddons(for: "b")
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
    }
}
