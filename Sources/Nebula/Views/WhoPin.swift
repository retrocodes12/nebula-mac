import SwiftUI
import NebulaCore
#if os(macOS)
import AppKit
#endif

/// What a PIN screen is for (10-23): checking a locked profile's PIN before entering or editing it, or choosing one.
struct PinAsk: Equatable {
    enum Mode { case check, choose }
    enum Purpose { case enter, edit, set }
    let id: String
    let mode: Mode
    let purpose: Purpose
}

/// The PIN screen, inside the picker overlay: the profile's monogram, a title, four dots, a one-line message and a
/// keypad 1–9 / (blank) 0 ⌫, then "Forgot PIN?" (check only) and "Cancel". On a Mac the number keys type, Delete
/// deletes and Esc cancels; on a phone it is touch. Cancel returns to where it came from (the picker or the editor).
struct WhoPin: View {
    @EnvironmentObject var model: AppModel
    let ask: PinAsk
    let onPassed: () -> Void
    let onCancel: () -> Void

    @State private var typed = ""
    @State private var first = ""          // choosing: the first entry, waiting for the same again
    @State private var message = ""
    @State private var forgot = false
    @State private var password = ""
    @State private var busy = false
    @State private var holdTask: Task<Void, Never>?
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    private var viewer: Viewer { model.viewerList.first { $0.id == ask.id } ?? Viewer(id: ask.id, name: "", av: "") }
    private var holding: Bool { ask.mode == .check && model.pinHoldUntil > Date() }

    private var title: String {
        let name = model.viewerName(viewer)
        if ask.mode == .check { return "Enter the PIN for \(name)" }
        return first.isEmpty ? "Choose a 4-digit PIN for \(name)" : "Enter the same PIN again"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                WhoMonogram(hex: model.viewerAvatar(viewer), name: model.viewerName(viewer), size: 80)
                Text(title).scaledFont(size: 24, weight: .bold).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center).padding(.top, 18)
                if forgot {
                    forgotBody
                } else {
                    HStack(spacing: 18) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle().fill(i < typed.count ? Theme.ink : Color.clear)
                                .overlay(Circle().stroke(Theme.ink.opacity(0.7), lineWidth: 1.5))
                                .frame(width: 14, height: 14)
                        }
                    }
                    .padding(.top, 22)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(typed.count) of 4")
                    messageLine
                    keypad.padding(.top, 10)
                    if ask.mode == .check {
                        Button(action: { forgot = true; message = "" }) {
                            Text("Forgot PIN?").scaledFont(size: 15, weight: .medium).foregroundStyle(Theme.label2)
                                .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    }
                }
                Button(action: cancel) {
                    Text("Cancel").scaledFont(size: 17, weight: .semibold).foregroundStyle(Theme.label2)
                        .padding(.horizontal, 34).padding(.vertical, 12)
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 24)
        }
        .onAppear {
            if holding { holdMessage() }
            #if os(macOS)
            watchKeys()
            #endif
        }
        .onDisappear {
            holdTask?.cancel()
            #if os(macOS)
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            #endif
        }
    }

    private var messageLine: some View {
        Text(message.isEmpty ? " " : message)
            .scaledFont(size: 14, weight: .medium)
            .foregroundStyle(Theme.danger)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: 360, minHeight: 22)
            .padding(.top, 14)
    }

    @ViewBuilder private var forgotBody: some View {
        if model.canResetPin {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .padding(.top, 28)
                .onSubmit { reset() }
            messageLine
            Button(action: reset) {
                Text("Remove the PIN").scaledFont(size: 17, weight: .semibold).foregroundStyle(.black)
                    .padding(.horizontal, 34).padding(.vertical, 12)
                    .background(Capsule().fill(Color(hex: "#F2F2F7")))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(password.isEmpty || busy)
            .opacity(password.isEmpty || busy ? 0.5 : 1)
            .padding(.top, 14)
        } else {
            Text("Sign in to your Nebula account on this device first — its password resets the PIN.")
                .scaledFont(size: 15).foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 28)
        }
    }

    private var keypad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "del"]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 22), count: 3), spacing: 12) {
            ForEach(keys.indices, id: \.self) { i in
                let k = keys[i]
                if k.isEmpty {
                    Color.clear.frame(width: 64, height: 64)
                } else {
                    Button(action: { k == "del" ? delete() : digit(k) }) {
                        Circle().fill(k == "del" ? Color.clear : Theme.surface)
                            .overlay(Circle().stroke(k == "del" ? Color.clear : Theme.line, lineWidth: 1))
                            .frame(width: 64, height: 64)
                            .overlay(Group {
                                if k == "del" {
                                    Image(systemName: "delete.left").font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.ink)
                                } else {
                                    Text(k).font(.system(size: 30, weight: .regular)).foregroundStyle(Theme.ink)
                                }
                            })
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(k == "del" ? "Delete" : k)
                }
            }
        }
        .opacity(holding ? 0.4 : 1)
    }

    // MARK: keys

    private func digit(_ d: String) {
        guard !holding, !forgot, typed.count < 4 else { return }
        typed += d
        if typed.count == 4 {
            let pin = typed
            // let the fourth dot show before the answer
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                if typed == pin { finish(pin) }
            }
        }
    }

    private func delete() {
        guard !holding, !forgot, !typed.isEmpty else { return }
        typed.removeLast()
    }

    private func finish(_ pin: String) {
        typed = ""
        switch ask.mode {
        case .check:
            // a lock removed elsewhere meanwhile: nothing left to check
            guard let lock = viewer.lock else { model.pinRight(ask.id); onPassed(); return }
            if lock.matches(pin) { model.pinRight(ask.id); onPassed(); return }
            model.pinWrong += 1
            if model.pinWrong >= 5 {
                model.pinWrong = 0
                model.pinHoldUntil = Date().addingTimeInterval(30)
                holdMessage()
            } else {
                message = "Wrong PIN."
            }
        case .choose:
            if first.isEmpty { first = pin; message = ""; return }
            if pin == first { model.setPin(ask.id, pin: pin); onPassed(); return }
            first = ""
            message = "The PINs didn't match — try again."
        }
    }

    private func holdMessage() {
        message = "Too many tries — wait 30 seconds."
        holdTask?.cancel()
        let until = model.pinHoldUntil
        holdTask = Task { @MainActor in
            let wait = max(0, until.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 50_000_000)
            if !Task.isCancelled { message = "" }
        }
    }

    private func reset() {
        guard !password.isEmpty, !busy else { return }
        busy = true; message = ""
        let pw = password, id = ask.id
        Task { @MainActor in
            let err = await model.checkAccountPassword(pw)
            busy = false
            if let err = err { message = err; return }
            password = ""
            model.removePin(id, forgot: true)
            onPassed()
        }
    }

    private func cancel() { onCancel() }

    #if os(macOS)
    /// Number keys type a digit, Delete takes one back, Esc cancels. While the password field is up its keys are its own.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            if !ev.modifierFlags.intersection([.command, .control, .option]).isEmpty { return ev }
            if ev.keyCode == 53 { cancel(); return nil }
            if forgot { return ev }
            if ev.keyCode == 51 || ev.keyCode == 117 { delete(); return nil }
            if let c = ev.charactersIgnoringModifiers, c.count == 1, let ch = c.first, ch >= "0" && ch <= "9" {
                digit(String(ch)); return nil
            }
            return ev
        }
    }
    #endif
}
