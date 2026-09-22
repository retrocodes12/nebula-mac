import SwiftUI
import UIKit
import AVFoundation
import NebulaCore

/// Nebula for iPhone. The model, the add-on client, the engine and every page are the Mac app's,
/// compiled again for the phone; what lives here is the shell around them — the tab bar, the
/// touch player, and the handful of things only a phone has (an audio session, an idle timer).
@main
struct NebulaPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneDelegate.self) private var delegate
    @StateObject private var model = AppModel(store: AppInfo.store())
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environmentObject(model)
                .onOpenURL { model.handle(url: $0) }
                .task { Launch.apply(to: model) }
        }
        .onChange(of: phase) { p in
            switch p {
            case .active:
                // what changed on the TV or the Mac while the phone was away (throttled in Cloud)
                Task { await model.cloud.pullAll() }
            case .background:
                Sync.flushInBackground(model.cloud)
            default:
                // iOS can suspend us without warning, so the last seconds of progress go up as
                // soon as the app leaves the screen rather than when it closes
                Task { await model.cloud.flush() }
            }
        }
    }
}

enum Sync {
    /// A backgrounded app is suspended within moments; the last push runs as an expiring
    /// activity, which holds the process up until it is done (or iOS says time is up).
    static func flushInBackground(_ cloud: Cloud) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Send the last progress to the profile") { expired in
            guard !expired else { return }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await cloud.flush()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 20)
        }
    }
}

final class PhoneDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // the build machine's way in: `simctl launch --console … --args --smoke <address>` plays
        // with no window and prints the same line the Mac's rig does
        if let i = CommandLine.arguments.firstIndex(of: "--smoke") {
            Smoke.start(Array(CommandLine.arguments[(i + 1)...]))
            return true
        }
        // no audio session here: activating one at launch stops whatever the viewer was
        // listening to just for opening the app — it starts with playback (PhoneRoot)
        return true
    }
}

/// Sound on a phone needs asking for: without a playback session the engine's output is silenced
/// by the ring switch and stops the moment the screen locks. The session is only held while
/// something plays — it is not mixable, so holding it stops the viewer's music.
enum Audio {
    static func begin() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback)
        try? s.setActive(true)
    }

    /// Give the sound back, and tell the app that had it (the music) that it can go on.
    static func end() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Launch arguments the screenshot rig uses to land on a page without touching anything.
/// `@MainActor` because a View gets that by inference from `body` and a bare enum does not —
/// every call below reaches into the model, which is main-actor bound.
@MainActor
enum Launch {
    static func apply(to model: AppModel) {
        let a = CommandLine.arguments
        func value(_ flag: String) -> String? {
            a.firstIndex(of: flag).flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil }
        }
        if let t = value("--tab").flatMap(Tab.init(rawValue:)) { model.select(t) }
        if let raw = value("--addon") {
            Task { if let e = await model.installAddon(raw) { model.say(e, error: true) } }
        }
        if let address = value("--play") {
            var c = URLComponents()
            c.scheme = "nebula"
            c.host = "play"
            c.queryItems = [URLQueryItem(name: "mpd", value: address), URLQueryItem(name: "t", value: value("--title") ?? "Nebula")]
            if let u = c.url { model.handle(url: u) }
        }
    }
}
