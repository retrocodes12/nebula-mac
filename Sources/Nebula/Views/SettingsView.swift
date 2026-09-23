import SwiftUI
import NebulaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var seekStep = 10
    @State private var resume = true
    @State private var autoplayNext = true
    @State private var hwdec = true
    @State private var maxHeight = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Settings").scaledFont(size: 30, weight: .bold).foregroundStyle(Theme.ink).padding(.top, 56)

                section("Profile") { ProfilePanel() }

                section("Appearance") {
                    Panel {
                        PanelRow(title: "Accent", detail: "The one colour Nebula uses.") {
                            HStack(spacing: 8) {
                                ForEach(Prefs.accents, id: \.hex) { a in
                                    Button(action: { model.prefs.accent = a.hex; model.accentHex = a.hex }) {
                                        Circle().fill(Color(hex: a.hex)).frame(width: 22, height: 22)
                                            .overlay(Circle().strokeBorder(.white, lineWidth: model.accentHex == a.hex ? 2 : 0).padding(-3))
                                    }
                                    .buttonStyle(.plain).help(a.name)
                                }
                            }
                        }
                    }
                }

                section("Playback") {
                    Panel {
                        PanelRow(title: "Pick up where you left off", detail: "Start a title from the place you stopped.") {
                            Toggle("", isOn: $resume).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                        Hairline()
                        PanelRow(title: "Play the next episode", detail: "Offer it as the credits start, and go on when the episode ends.") {
                            Toggle("", isOn: $autoplayNext).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                        Hairline()
                        PanelRow(title: skipTitle, detail: skipDetail) {
                            HStack(spacing: 6) { ForEach([5, 10, 15, 30], id: \.self) { s in Chip(text: "\(s) s", on: seekStep == s) { seekStep = s } } }
                        }
                        Hairline()
                        PanelRow(title: "Picture quality", detail: "For streams that come in several qualities, such as live sports. Lower it on a slow connection.") {
                            HStack(spacing: 6) { ForEach([0, 1080, 720, 480], id: \.self) { h in Chip(text: h == 0 ? "Best" : "\(h)p", on: maxHeight == h) { maxHeight = h } } }
                        }
                        Hairline()
                        PanelRow(title: "Decode on the graphics chip", detail: "\(Platform.hardwareDecodingGain) Switch it off if a film shows a broken picture.") {
                            Toggle("", isOn: $hwdec).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                    }
                }

                section("About") {
                    Panel {
                        PanelRow(title: Platform.appTitle, detail: model.updateTag.map { "Version \(AppInfo.version) · \($0) is out" } ?? "Version \(AppInfo.version) · up to date") {
                            Button(model.updateTag == nil ? "Releases" : "Get the update") {
                                if let u = URL(string: AppInfo.repo + "/releases/latest") { Platform.open(u) }
                            }
                            .buttonStyle(PillButtonStyle(filled: model.updateTag != nil))
                        }
                        #if os(macOS)
                        Hairline()
                        PanelRow(title: "Keyboard", detail: "Space play or pause · ← → skip · ↑ ↓ volume · F full screen · M mute · C subtitles · A audio · I info · N next episode · Esc back") { EmptyView() }
                        #endif
                    }
                }
            }
            .frame(maxWidth: Theme.cap(720), alignment: .leading)
            .padding(.horizontal, Theme.pad).padding(.bottom, 50)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .onAppear {
            seekStep = model.prefs.seekStep; resume = model.prefs.resume
            autoplayNext = model.prefs.autoplayNext; hwdec = model.prefs.hardwareDecoding; maxHeight = model.prefs.maxHeight
        }
        .onChange(of: seekStep) { model.prefs.seekStep = $0 }
        .onChange(of: resume) { model.prefs.resume = $0 }
        .onChange(of: autoplayNext) { model.prefs.autoplayNext = $0 }
        .onChange(of: hwdec) { model.prefs.hardwareDecoding = $0 }
        .onChange(of: maxHeight) { model.prefs.maxHeight = $0 }
    }

    // the step is the arrow keys' on a Mac, the double tap's and the skip buttons' on a phone
    #if os(macOS)
    private let skipTitle = "Skip with the arrow keys"
    private let skipDetail = "How far ← and → move. Hold Shift for a minute."
    #else
    private let skipTitle = "Skip by"
    private let skipDetail = "How far a double tap or the skip buttons move."
    #endif

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(title)
            content()
        }
    }
}

/// A Nebula profile is an @handle and a password. Signed in, this Mac shares add-ons, progress
/// and My List with the TV, the phone and the browser.
struct ProfilePanel: View {
    @EnvironmentObject var model: AppModel
    enum Mode { case signIn, create }
    @State private var mode: Mode = .signIn
    @State private var handle = ""
    @State private var name = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var recovery: String?
    @State private var devices: [DeviceRec] = []
    @State private var tvCode = ""
    @State private var tvNote: String?

    var body: some View {
        if let key = recovery { recoveryCard(key) }
        else if let p = model.profile { signedIn(p) }
        else { form }
    }

    private var form: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Chip(text: "Sign in", on: mode == .signIn) { mode = .signIn; error = nil }
                    Chip(text: "Create a profile", on: mode == .create) { mode = .create; error = nil }
                }
                Text(mode == .signIn ? "Your add-ons, your place in everything and My List come with you."
                                     : "A handle and a password — no email. What is on this \(Platform.deviceWord) becomes the profile.")
                    .scaledFont(size: 12.5).foregroundStyle(Theme.label2)
                field("@handle", text: $handle).entry(.handle)
                if mode == .create { field("Name", text: $name) }
                SecureField("Password", text: $password)
                    .entry(mode == .create ? .newPassword : .password)
                    .textFieldStyle(.plain).scaledFont(size: 14).padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface2))
                    .onSubmit(submit)
                if let e = error { Text(e).scaledFont(size: 12.5).foregroundStyle(Theme.danger) }
                Button(action: submit) { if busy { ProgressView().controlSize(.small) } else { Text(mode == .signIn ? "Sign in" : "Create profile") } }
                    .buttonStyle(PillButtonStyle()).disabled(busy)
            }
            .padding(16)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).scaledFont(size: 14).padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface2))
            .onSubmit(submit)
    }

    private func recoveryCard(_ key: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep this recovery key").scaledFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                Text("It is the only way back in if you forget the password, and it is shown once.").scaledFont(size: 12.5).foregroundStyle(Theme.label2)
                Text(key).scaledFont(size: 18, weight: .semibold, design: .monospaced).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface2))
                HStack(spacing: 10) {
                    Button("Copy") { Platform.copy(key); model.say("Copied.") }
                        .buttonStyle(PillButtonStyle(filled: false))
                    Button("I’ve saved it") { recovery = nil }.buttonStyle(PillButtonStyle())
                }
            }
            .padding(16)
        }
    }

    private func signedIn(_ p: Profile) -> some View {
        Panel {
            HStack(spacing: 14) {
                Circle().fill(Color(hex: p.avatar)).frame(width: 44, height: 44)
                    .overlay(Text(String(p.name.prefix(1)).uppercased()).font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).scaledFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                    Text("@\(p.handle)").scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label2)
                }
                Spacer()
                Button("Sign out") {
                    Task { await model.cloud.signOut(); devices = []; model.say("Signed out. Nothing on this \(Platform.deviceWord) was deleted.") }
                }
                .buttonStyle(PillButtonStyle(filled: false))
            }
            .padding(16)
            Hairline()
            PanelRow(title: "Sign in a TV", detail: tvNote ?? "Type the 6-character code the TV is showing.") {
                HStack(spacing: 8) {
                    TextField("CODE", text: $tvCode)
                        .entry(.code)
                        .textFieldStyle(.plain).scaledFont(size: 14, weight: .semibold, design: .monospaced).multilineTextAlignment(.center)
                        .padding(.vertical, 6).frame(width: 96).frame(minHeight: 34).background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                        .onSubmit(approveTv)
                    Button("Approve", action: approveTv).buttonStyle(PillButtonStyle(filled: false))
                }
            }
            if !devices.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow("Devices").padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ForEach(devices) { d in
                        HStack(spacing: 10) {
                            Image(systemName: icon(d.plat)).foregroundStyle(Theme.label2).frame(width: 20)
                            Text(d.name).scaledFont(size: 13.5).foregroundStyle(Theme.ink)
                            if d.me { Text("THIS \(Platform.deviceWord.uppercased())").scaledFont(size: 9.5, weight: .semibold, design: .monospaced).tracking(1).foregroundStyle(model.accent) }
                            Spacer()
                            if !d.me {
                                Button("Sign out") { Task { if let e = await model.cloud.removeDevice(d.id) { model.say(e, error: true) }; await refresh() } }
                                    .buttonStyle(.plain).scaledFont(size: 12, weight: .medium).foregroundStyle(Theme.label2)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .task { await refresh() }
    }

    private func icon(_ plat: String) -> String {
        switch plat {
        case "macos", "desktop", "windows", "linux": return "desktopcomputer"
        case "ios", "android": return "iphone"
        case "androidtv", "webos", "tv": return "tv"
        default: return "globe"
        }
    }

    private func refresh() async { devices = await model.cloud.refreshProfile() ?? devices }

    private func submit() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            if mode == .signIn {
                error = await model.cloud.signIn(handle: handle, password: password)
                if error == nil { model.say("Signed in. Your add-ons and progress are on their way.") }
            } else {
                let (key, err) = await model.cloud.createProfile(handle: handle, name: name.isEmpty ? handle : name, password: password)
                error = err; recovery = key
            }
            if error == nil { password = ""; model.addons = model.addonStore.all(); model.invalidateHome() }
            busy = false
        }
    }

    private func approveTv() {
        Task {
            let (device, err) = await model.cloud.approveTv(code: tvCode)
            if let d = device { tvNote = "\(d) is signed in."; tvCode = ""; await refresh() } else { tvNote = err }
        }
    }
}
