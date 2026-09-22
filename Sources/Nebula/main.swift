import SwiftUI
import AppKit
import NebulaCore

// Three ways in besides the window, all for the build machines that stand in for a Mac on a
// desk: `--icon` draws the app icon, `--smoke` plays a stream with no window and reports whether time moved, `--shots`
// draws every screen into PNGs.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--smoke") {
    Smoke.run(Array(arguments[(i + 1)...]))
} else if let i = arguments.firstIndex(of: "--icon"), arguments.count > i + 1 {
    IconMaker.run(arguments[i + 1])
} else {
    NebulaApp.main()
}

struct NebulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel(store: AppInfo.store())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 640)
                .onOpenURL { model.handle(url: $0) }
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, t in
                    Button(t.title) { model.player = nil; model.select(t) }.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Divider()
                Button("Back") { if !model.path.isEmpty { model.path.removeLast() } }.keyboardShortcut("[", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let i = CommandLine.arguments.firstIndex(of: "--shots"), CommandLine.arguments.count > i + 1 {
            let folder = CommandLine.arguments[i + 1]
            Task { @MainActor in Shots.run(into: folder, delegate: self) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Back at the front: what changed on the TV or the phone meanwhile comes in (Cloud keeps
    /// this to one pull per 45 s).
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let cloud = model?.cloud else { return }
        Task { await cloud.pullAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // the last few seconds of progress should reach the profile before the process goes
        guard let cloud = model?.cloud else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await cloud.flush(); done.signal() }
        _ = done.wait(timeout: .now() + 2.5)
    }
}
