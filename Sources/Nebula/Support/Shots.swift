import SwiftUI
import AppKit
import NebulaCore

/// `Nebula --shots <folder>` walks the real window through its screens and writes a PNG of each.
/// Nobody on this project has a Mac; this is how the interface gets looked at.
@MainActor
enum Shots {
    static func run(into folder: String, delegate: AppDelegate) {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            var model: AppModel?
            for _ in 0..<100 where model == nil || NSApp.windows.first(where: { $0.isVisible }) == nil {
                model = delegate.model
                await pause(0.1)
            }
            guard let m = model, let window = NSApp.windows.first(where: { $0.isVisible }) else { log("no window"); exit(2) }
            window.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
            if let extra = ProcessInfo.processInfo.environment["NEBULA_SHOTS_ADDON"], !extra.isEmpty { _ = await m.installAddon(extra) }

            await settle { !m.homeRows.isEmpty }
            await snap(window, dir, "01-home")

            let series = m.homeRows.flatMap { r in r.items.map { ($0, r.addon) } }.first { $0.0.type == "series" }
            let film = m.homeRows.flatMap { r in r.items.map { ($0, r.addon) } }.first { $0.0.type == "movie" }
            if let s = series {
                m.open(s.0, addonUrl: s.1.manifestUrl)
                await settle(atLeast: 5) { true }
                await snap(window, dir, "02-series")
                m.path.removeAll()
            }
            if let f = film {
                m.open(f.0, addonUrl: f.1.manifestUrl)
                await settle(atLeast: 4) { true }
                await snap(window, dir, "03-film")
                m.push(.streams(StreamsTarget(type: f.0.type, id: f.0.id, item: f.0, addonUrl: f.1.manifestUrl)))
                await settle(atLeast: 6) { true }
                await snap(window, dir, "04-streams")
                m.path.removeAll()
            }
            // a row of live events, when the rig added an add-on that has them
            if let live = m.homeRows.first(where: { $0.catalog.type != "movie" && $0.catalog.type != "series" }), let ev = live.items.first {
                m.push(.streams(StreamsTarget(type: ev.type, id: ev.id, item: ev, addonUrl: live.addon.manifestUrl)))
                await settle(atLeast: 10) { true }
                await snap(window, dir, "05-live-streams")
                m.path.removeAll()
            }
            if let row = m.homeRows.first {
                m.push(.catalog(CatalogTarget(addon: row.addon, catalog: row.catalog)))
                await settle(atLeast: 4) { true }
                await snap(window, dir, "06-catalog")
                m.path.removeAll()
            }
            for (i, t) in [Tab.search, .library, .addons, .settings].enumerated() {
                m.select(t)
                await settle(atLeast: t == .search ? 5 : 1.5) { true }
                await snap(window, dir, "0\(7 + i)-\(t.rawValue)")
            }
            // the player, in the real window: the picture proves the Metal path, not just the decoder
            if let address = ProcessInfo.processInfo.environment["NEBULA_SHOTS_PLAY"], !address.isEmpty {
                m.select(.home)
                let item = MetaItem(id: "shots", type: "link", name: "Big Buck Bunny")
                m.play(StreamItem(name: "", title: "", url: address), target: StreamsTarget(type: "link", id: "", item: item, addonUrl: ""), from: nil)
                await pause(9)                         // long enough to be playing, and for the chrome to let go
                await snap(window, dir, "11-player-clean")
                // Space pauses, and a paused player keeps its chrome up
                if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                             isARepeat: false, keyCode: 49) { NSApp.postEvent(ev, atStart: false) }
                await pause(1.5)
                await snap(window, dir, "12-player-chrome")
                m.player = nil
                await pause(1)
            }
            // the narrowest window the app allows: the hero's art must not widen the page
            window.setFrame(NSRect(x: 40, y: 40, width: 1040, height: 760), display: true)
            m.select(.home)
            await settle(atLeast: 2) { true }
            await snap(window, dir, "14-home-narrow")
            log("done")
            exit(0)
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("shots: \(s)\n".utf8)) }

    static func pause(_ secs: Double) async { try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000)) }

    /// Wait for a condition, then for the pictures to stop arriving.
    static func settle(atLeast: Double = 1, _ ready: () -> Bool) async {
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            await pause(0.25)
            if Date().timeIntervalSince(start) >= atLeast && ready() && !ImageLoader.shared.busy { break }
        }
        await pause(0.8)
    }

    static func snap(_ window: NSWindow, _ dir: URL, _ name: String) async {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent(name + ".png")) }
        }
        // the window server's own picture has the materials in it; it needs a permission a
        // build machine may not give, so it is a bonus beside the drawing above
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), dir.appendingPathComponent(name + "-screen.png").path]
        try? p.run()
        p.waitUntilExit()
        log(name)
    }
}
