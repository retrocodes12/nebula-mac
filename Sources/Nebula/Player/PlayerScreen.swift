import SwiftUI
import AppKit
import NebulaCore

/// The player: the video edge to edge, Apple-TV glass chrome over it that gets out of the way.
struct PlayerScreen: View {
    @EnvironmentObject var model: AppModel
    let request: PlayRequest
    @StateObject private var mpv: MPVController
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var menu: PlayerMenu?
    @State private var scrubbing: Double?
    @State private var keyMonitor: Any?
    @State private var captions = PlaybackRules.CaptionGate()
    /// What the engine was handed, so Try again can hand it the same.
    @State private var resolved: String?
    @State private var resolvedKeys: [String: String] = [:]
    @State private var nextOffered = false
    @State private var nextBusy = false
    @State private var lastSaved: Double = -100
    @State private var cursorHidden = false
    /// Held while a picture is moving, so the display does not dim and sleep under a film.
    @State private var awake: NSObjectProtocol?

    enum PlayerMenu: String { case audio, subtitles, speed, info }

    init(request: PlayRequest, hardwareDecoding: Bool) {
        self.request = request
        _mpv = StateObject(wrappedValue: MPVController(hardwareDecoding: hardwareDecoding))
    }

    var next: Episode? { model.nextEpisode(after: request.target) }
    private var chromeShown: Bool { chromeVisible || mpv.paused || menu != nil || mpv.failure != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(controller: mpv).ignoresSafeArea()
            // the whole picture is a button: a click pauses, a double click goes full screen
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture { if menu != nil { menu = nil } else { mpv.togglePause(); wake() } }

            if mpv.buffering && mpv.failure == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let f = mpv.failure { failureCard(f) }

            chrome
                .opacity(chromeShown ? 1 : 0)
                .allowsHitTesting(chromeShown)               // hidden controls must not take clicks
                .animation(.easeOut(duration: 0.25), value: chromeShown)

            if nextOffered, let n = next, mpv.failure == nil { nextPill(n) }
        }
        .onContinuousHover { phase in if case .active = phase { wake() } }
        .onAppear(perform: start)
        .onDisappear(perform: finish)
        .onChange(of: mpv.timePos) { t in tick(t) }
        .onChange(of: mpv.ended) { e in if e { reachedEnd() } }
        .onChange(of: mpv.loaded) { l in if l { loadedNow() } }
        .onChange(of: mpv.volume) { v in model.prefs.volume = v }
        .onChange(of: playing) { keepDisplayAwake($0) }
    }

    /// Playing, not paused, not at the end, not failed.
    private var playing: Bool { mpv.loaded && !mpv.paused && !mpv.ended && mpv.failure == nil }

    private func keepDisplayAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing a video")
        } else if !on, let a = awake {
            ProcessInfo.processInfo.endActivity(a)
            awake = nil
        }
    }

    // MARK: chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                GlassCircle(icon: "chevron.left", label: "Back") { close() }
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let k = request.kicker { Text(k).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                    Text(sourceLine).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 36)

            Spacer()

            HStack(spacing: 34) {
                GlassCircle(icon: "gobackward.\(stepIcon)", label: "Back \(model.prefs.seekStep) seconds", size: 52) { mpv.seek(by: -Double(model.prefs.seekStep)); wake() }
                    .opacity(mpv.isLive && !mpv.seekable ? 0.3 : 1)
                GlassCircle(icon: mpv.ended ? "arrow.counterclockwise" : mpv.paused ? "play.fill" : "pause.fill", label: mpv.paused ? "Play" : "Pause", size: 72) {
                    if mpv.ended { mpv.seek(to: 0); mpv.setPaused(false) } else { mpv.togglePause() }
                    wake()
                }
                GlassCircle(icon: "goforward.\(stepIcon)", label: "Forward \(model.prefs.seekStep) seconds", size: 52) { mpv.seek(by: Double(model.prefs.seekStep)); wake() }
                    .opacity(mpv.isLive ? 0.3 : 1)
            }
            .opacity(mpv.failure == nil ? 1 : 0)
            .allowsHitTesting(mpv.failure == nil)          // drawn over the failure card's buttons

            Spacer()

            VStack(spacing: 14) {
                if let m = menu { menuPanel(m).transition(.opacity.combined(with: .move(edge: .bottom))) }
                scrubber
                HStack(spacing: 10) {
                    GlassCircle(icon: mpv.muted || mpv.volume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Mute", size: 38) { mpv.toggleMute() }
                    Slider(value: Binding(get: { mpv.volume }, set: { mpv.setVolume($0) }), in: 0...100)
                        .frame(width: 110).tint(.white).controlSize(.small)
                    Spacer()
                    barButton("captions.bubble", "Subtitles", .subtitles)
                    barButton("waveform", "Audio", .audio)
                    barButton("speedometer", "Speed", .speed)
                    barButton("info.circle", "Info", .info)
                    GlassCircle(icon: "arrow.up.left.and.arrow.down.right", label: "Full screen", size: 38) { toggleFullScreen() }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
        .background(
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.22),
                                   .init(color: .clear, location: 0.62), .init(color: .black.opacity(0.7), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var stepIcon: String { [5, 10, 15, 30, 45, 60].contains(model.prefs.seekStep) ? String(model.prefs.seekStep) : "10" }

    private var sourceLine: String {
        var parts: [String] = []
        if let a = request.streamAddon { parts.append(a.name) }
        if mpv.videoHeight > 0 { parts.append("\(mpv.videoHeight)p") }
        return parts.joined(separator: " · ").uppercased()
    }

    private func barButton(_ icon: String, _ label: String, _ m: PlayerMenu) -> some View {
        GlassCircle(icon: icon, label: label, size: 38, on: menu == m) { withAnimation(.easeOut(duration: 0.18)) { menu = menu == m ? nil : m }; wake() }
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            if mpv.isLive {
                TimePill(text: "LIVE", live: true, accent: model.accent)
                Capsule().fill(.white.opacity(0.25)).frame(height: 6)
            } else {
                TimePill(text: Fmt.clock(scrubbing ?? mpv.timePos))
                Scrubber(position: scrubbing ?? mpv.timePos, duration: mpv.duration, buffered: mpv.timePos + mpv.cacheAhead, accent: model.accent,
                         onDrag: { scrubbing = $0; wake() },
                         onCommit: { mpv.seek(to: $0); scrubbing = nil; wake() })
                TimePill(text: "−" + Fmt.clock(max(0, mpv.duration - (scrubbing ?? mpv.timePos))))
            }
        }
    }

    // MARK: menus

    @ViewBuilder
    private func menuPanel(_ m: PlayerMenu) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                switch m {
                case .audio:
                    menuTitle("Audio")
                    let list = mpv.tracks.filter { $0.type == "audio" }
                    if list.isEmpty { menuNote("This stream has one soundtrack.") }
                    ForEach(list) { t in menuRow(t.label, on: t.selected) { mpv.selectTrack("audio", id: t.id); model.prefs.audioLang = t.lang } }
                case .subtitles:
                    menuTitle("Subtitles")
                    let list = mpv.tracks.filter { $0.type == "sub" }
                    menuRow("Off", on: !list.contains { $0.selected }) { mpv.selectTrack("sub", id: nil); model.prefs.subLang = "" }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(list) { t in menuRow(t.label + (t.external ? "" : " · in the file"), on: t.selected) { mpv.selectTrack("sub", id: t.id); model.prefs.subLang = t.lang } }
                        }
                    }
                    .frame(maxHeight: 280)
                    if list.isEmpty { menuNote(captions.settled ? "No subtitles were found for this." : "Looking for subtitles…") }
                case .speed:
                    menuTitle("Speed")
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                        menuRow(s == 1 ? "Normal" : String(format: "%g×", s), on: abs(mpv.speed - s) < 0.01) { mpv.setSpeed(s) }
                    }
                case .info:
                    menuTitle("Info")
                    ForEach(infoRows, id: \.0) { row in
                        HStack { Text(row.0).foregroundStyle(.white.opacity(0.6)); Spacer(minLength: 24); Text(row.1).foregroundStyle(.white) }
                            .font(.system(size: 12, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 5)
                    }
                }
            }
            .padding(8)
            .frame(width: 320, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
        }
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let v = mpv.tracks.first(where: { $0.type == "video" && $0.selected }) { rows.append(("Picture", "\(v.codec.uppercased()) \(mpv.videoHeight > 0 ? "\(mpv.videoHeight)p" : "")")) }
        if let a = mpv.tracks.first(where: { $0.type == "audio" && $0.selected }) { rows.append(("Sound", "\(a.codec.uppercased())\(a.channels > 0 ? " · \(a.channels) ch" : "")")) }
        rows.append(("Decoding", mpv.hwdec.isEmpty || mpv.hwdec == "no" ? "On the processor" : "On the graphics chip"))
        rows.append(("Buffered", "\(Int(mpv.cacheAhead)) s ahead"))
        if !request.stream.clearKeys.isEmpty || protected { rows.append(("Protected", "Yes")) }
        if let h = URL(string: request.stream.url)?.host { rows.append(("From", h)) }
        return rows
    }

    private func menuTitle(_ t: String) -> some View {
        Eyebrow(t).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
    }

    private func menuNote(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func menuRow(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { action(); wake() }) {
            HStack {
                Text(text).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.white : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func failureCard(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.8))
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) {
                if resolved != nil { Button("Try again") { retry() }.buttonStyle(PillButtonStyle(filled: false)) }
                Button("Try another stream") { close() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }

    private func nextPill(_ n: Episode) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: { playNext(n) }) {
                    HStack(spacing: 10) {
                        if nextBusy { ProgressView().controlSize(.small) } else { Image(systemName: "forward.end.fill") }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Next episode").font(.system(size: 13, weight: .semibold))
                            Text(Ids.episodeTag(n.id).map { "\($0) · \(n.name)" } ?? n.name).font(.system(size: 11)).opacity(0.7).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 48)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                    .environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 28).padding(.bottom, 120)
        }
    }

    // MARK: life cycle

    @State private var protected = false

    private func start() {
        mpv.setVolume(model.prefs.volume)
        let s = request.stream
        Task {
            let got = await PlaybackRules.source(for: s, maxHeight: model.prefs.maxHeight, stremio: model.stremio)
            protected = !got.keys.isEmpty
            resolved = got.address; resolvedKeys = got.keys
            mpv.load(url: got.address, startAt: request.startAt, keys: got.keys, headers: s.headers)
        }
        Task {
            let t = request.target
            let subs = await model.addonSubtitles(type: t.type, id: t.id)
            if captions.addonsAnswered(subs) { attachSubs() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in handleKey(ev) ? nil : ev }
        wake()
    }

    private func loadedNow() {
        if captions.fileLoaded() { attachSubs() }
        let want = model.prefs.audioLang
        if !want.isEmpty, let t = mpv.tracks.first(where: { $0.type == "audio" && $0.lang == want }), !t.selected { mpv.selectTrack("audio", id: t.id) }
    }

    /// Called once, when the gate opens: the file is open and the add-ons have answered.
    private func attachSubs() {
        PlaybackRules.attachCaptions(captions, stream: request.stream, want: model.prefs.subLang, to: mpv)
    }

    private func tick(_ t: Double) {
        guard mpv.loaded, !mpv.isLive, mpv.duration > 0 else { return }
        if abs(t - lastSaved) >= 5 { lastSaved = t; save() }
        if model.prefs.autoplayNext, next != nil { nextOffered = mpv.duration - t <= 40 }
    }

    private func save() {
        guard mpv.loaded, !mpv.isLive, mpv.duration > 0 else { return }
        model.progress.note(PlaybackRules.record(target: request.target, pos: mpv.timePos, dur: mpv.duration))
    }

    private func reachedEnd() {
        guard !mpv.isLive else { return }
        guard PlaybackRules.reachedTheEnd(pos: mpv.timePos, dur: mpv.duration) else {
            // the connection went, not the film: keep the place and say so
            save()
            mpv.failure = PlaybackRules.cutShort
            return
        }
        model.progress.note(PlaybackRules.doneRecord(target: request.target))
        if let n = next, model.prefs.autoplayNext { playNext(n) }
    }

    /// The same release of the next episode when the add-on says which that is, else its first stream.
    private func playNext(_ n: Episode) {
        guard !nextBusy else { return }
        nextBusy = true
        var target = request.target
        target.id = n.id; target.episode = n
        let group = request.stream.bingeGroup, origin = request.streamAddon
        Task {
            let found = await PlaybackRules.nextStream(origin: origin, type: target.type, id: n.id, bingeGroup: group, stremio: model.stremio)
            nextBusy = false
            if let f = found {
                save()
                model.play(f.0, target: target, from: f.1, fresh: true)
            } else {
                close()
                model.push(.streams(target))
            }
        }
    }

    /// The same stream again, from where it stopped (a live one from its edge).
    private func retry() {
        guard let address = resolved else { return }
        let at = mpv.isLive ? 0 : max(0, mpv.timePos - 2)
        captions.reopened()
        mpv.load(url: address, startAt: at, keys: resolvedKeys, headers: request.stream.headers)
        wake()
    }

    private func finish() {
        save()
        keepDisplayAwake(false)
        hideTask?.cancel()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        mpv.close()
        Task { await model.cloud.flush() }
    }

    private func close() {
        if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        model.player = nil
    }

    private func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    /// Show the chrome and the pointer, then let both go after three quiet seconds.
    private func wake() {
        if !chromeVisible { chromeVisible = true }
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled || mpv.paused || menu != nil || mpv.failure != nil { return }
            chromeVisible = false
            if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        }
    }

    private func handleKey(_ ev: NSEvent) -> Bool {
        if ev.modifierFlags.contains(.command) { return false }
        let step = Double(model.prefs.seekStep)
        switch ev.keyCode {
        case 49: mpv.togglePause()                                   // space
        case 123: mpv.seek(by: ev.modifierFlags.contains(.shift) ? -60 : -step)   // ←
        case 124: mpv.seek(by: ev.modifierFlags.contains(.shift) ? 60 : step)     // →
        case 126: mpv.setVolume(mpv.volume + 5)                      // ↑
        case 125: mpv.setVolume(mpv.volume - 5)                      // ↓
        case 53:                                                     // esc
            if menu != nil { menu = nil }
            else if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            else { close() }
        default:
            switch ev.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen()
            case "m": mpv.toggleMute()
            case "k": mpv.togglePause()
            case "j": mpv.seek(by: -step)
            case "l": mpv.seek(by: step)
            case "c": menu = menu == .subtitles ? nil : .subtitles
            case "a": menu = menu == .audio ? nil : .audio
            case "i": menu = menu == .info ? nil : .info
            case "n": if let n = next { playNext(n) }
            default: return false
            }
        }
        wake()
        return true
    }
}

/// Apple-TV glass: a blurred circle with a hairline, the icon in white.


/// The thick rounded scrubber: played in the accent, buffered behind it, a knob only while held.
