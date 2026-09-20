import Foundation
import NebulaCore

/// `Nebula --smoke <address> [--keys kid:key,…] [--seconds n] [--direct]`
/// Plays with no window and no sound device, and exits 0 only if the clock moved. This is what
/// proves, on a build machine, that the engine links, opens the network, reads the container
/// and — with keys — decrypts.
enum Smoke {
    /// The Mac's way in: set the run up and turn the main loop ourselves.
    static func run(_ args: [String]) -> Never {
        start(args)
        RunLoop.main.run()
        exit(3)
    }

    /// The phone's way in: the app's own run loop is already turning, so only arm the timer.
    /// `--smoke` there is `simctl launch --console`, which reads the same line from stdout.
    static func start(_ args: [String]) {
        guard let address = args.first, !address.hasPrefix("--") else {
            FileHandle.standardError.write(Data("usage: Nebula --smoke <address> [--keys kid:key] [--seconds n]\n".utf8))
            exit(64)
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        let want = Double(value("--seconds") ?? "") ?? 4
        final class State { var keys: [String: String] = [:]; var first: Double?; var viaProxy = false }
        let state = State()
        state.keys = ClearKey.fromFragment("#clearkey=" + (value("--keys") ?? ""))
        let mpv = MPVController(headless: true)
        let started = Date()
        Task { @MainActor in
            // the same road the player takes: the loopback manifest cache, then the licence
            var play = address
            if ClearKey.looksLikeDash(address) && !args.contains("--direct") {
                if let m = await ManifestProxy.shared.open(address, headers: [:], maxHeight: 0) {
                    play = m.address
                    if state.keys.isEmpty { state.keys = await ClearKey.resolve(xml: m.xml, using: Stremio()) }
                }
            }
            if state.keys.isEmpty && ClearKey.looksLikeDash(address) { state.keys = await ClearKey.resolve(manifestUrl: address, using: Stremio()) }
            state.viaProxy = play != address
            mpv.load(url: play, keys: state.keys)
        }
        // the engine publishes on the main queue, so the main run loop has to turn
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            let waited = Date().timeIntervalSince(started)
            let report: (String, Int32) -> Void = { verdict, code in
                let video = mpv.tracks.first { $0.type == "video" && $0.selected }
                let line: JSONObject = ["verdict": verdict, "timePos": mpv.timePos, "duration": mpv.duration, "height": mpv.videoHeight,
                                        "video": video?.codec ?? "", "tracks": mpv.tracks.count, "keys": state.keys.count,
                                        "failure": mpv.failure ?? "", "waited": waited, "viaProxy": state.viaProxy, "ffmpeg": mpv.string("ffmpeg-version"), "mpv": mpv.string("mpv-version")]
                print(JSON.text(line))
                exit(code)
            }
            if mpv.failure != nil { report("failed", 1) }
            // a live stream's clock does not start at zero, so measure from the first reading
            if mpv.loaded && state.first == nil && mpv.timePos > 0 { state.first = mpv.timePos }
            if let f = state.first, mpv.timePos - f >= want { report("played", 0) }
            if mpv.ended { report(state.first != nil ? "played" : "ended-at-zero", state.first != nil ? 0 : 1) }
            if waited > 90 { report("timed-out", 2) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
