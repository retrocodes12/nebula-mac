import SwiftUI
import UIKit
import AVFoundation
import Combine
import NebulaCore

/// The phone's player. The engine, the source resolution, the captions, the resume point and the
/// next episode are `PlaybackRules` — the same ones the Mac uses. What is written here is only
/// what a finger needs: tap to wake, double tap a side to skip, drag the scrubber, and sheets
/// instead of the window's hovering panels.
@MainActor
struct PhonePlayer: View {
    @EnvironmentObject var model: AppModel
    let request: PlayRequest
    @StateObject private var mpv: MPVController
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var sheet: PlayerSheet?
    @State private var scrubbing: Double?
    @State private var captions = PlaybackRules.CaptionGate()
    @State private var sourceTask: Task<Void, Never>?
    @State private var subtitleTask: Task<Void, Never>?
    @State private var nextTask: Task<Void, Never>?
    @State private var manifestToken: String?
    @State private var finished = false
    /// What the engine was handed, so Try again can hand it the same.
    @State private var resolved: String?
    @State private var resolvedKeys: [String: String] = [:]
    @State private var retrying = false
    @State private var nextOffered = false
    @State private var nextBusy = false
    @State private var lastSaved: Double = -100
    @State private var protected = false
    @State private var locked = false
    @State private var flash: String?
    @State private var flashTask: Task<Void, Never>?
    /// Playing when a call (or another app's sound) took over, so play on when it hands back.
    @State private var resumeAfterInterruption = false
    /// The lock screen's card and the headphones' buttons.
    @State private var nowPlaying = NowPlaying()

    enum PlayerSheet: String, Identifiable { case audio, subtitles, speed, info; var id: String { rawValue } }

    init(request: PlayRequest, hardwareDecoding: Bool) {
        self.request = request
        _mpv = StateObject(wrappedValue: MPVController(hardwareDecoding: hardwareDecoding))
    }

    var next: Episode? { model.nextEpisode(after: request.target) }
    private var chromeShown: Bool { !locked && (chromeVisible || mpv.paused || mpv.failure != nil) }
    private var step: Double { Double(model.prefs.seekStep) }

    var body: some View {
        // The black, the picture and the tap zones run edge to edge; everything that is a
        // control stays inside the safe area — clear of the notch, the Dynamic Island and the
        // home indicator, which in landscape are at the sides and the foot of the picture.
        ZStack {
            Color.black.ignoresSafeArea()
            PhoneVideoSurface(controller: mpv).ignoresSafeArea()

            // the picture is two halves: one tap wakes the chrome, two skip a step
            HStack(spacing: 0) {
                tapZone(back: true)
                tapZone(back: false)
            }
            .ignoresSafeArea()

            if mpv.buffering && mpv.failure == nil {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if let f = flash { flashLabel(f) }

            chrome
                .opacity(chromeShown ? 1 : 0)
                .allowsHitTesting(chromeShown)
                .animation(.easeOut(duration: 0.25), value: chromeShown)

            if locked { lockPill }
            if nextOffered, let n = next, mpv.failure == nil, !locked { nextPill(n) }
            if let f = mpv.failure { failureCard(f) }
        }
        .background(keyboardKeys)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $sheet) { s in
            PlayerSheetView(kind: s, mpv: mpv, subsAdded: captions.settled, infoRows: infoRows, prefs: model.prefs,
                            onSubtitlePick: { captions.picked() })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .onAppear(perform: start)
        .onDisappear(perform: finish)
        .onChange(of: mpv.timePos) { t in tick(t) }
        .onChange(of: mpv.ended) { e in if e { reachedEnd() } }
        .onChange(of: mpv.loaded) { l in if l { loadedNow() } }
        .onChange(of: wantsAwake) { awakeNow($0) }
        // the hide timer stands down while a sheet is up, so closing one has to re-arm it or the
        // chrome sits there for good
        .onChange(of: sheet) { s in if s == nil { wake() } }
        // locked or in the background the sound goes on, the picture waits (setVideo says why)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            mpv.setVideo(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            ManifestProxy.shared.revive()
            mpv.setVideo(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main)) { n in
            interrupted(n)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { n in
            routeChanged(n)
        }
    }

    /// Playback is wanted: not paused, not at the end, not failed — playing, or still starting.
    /// Protected streams took 15 to 25 s to open on the build machine, and a phone set to lock
    /// after 30 s must not dim and lock in front of the spinner.
    private var wantsAwake: Bool { !mpv.paused && !mpv.ended && mpv.failure == nil }

    /// The player that keeps the screen from locking. One at a time: the next episode's player
    /// appears before the old one has gone, and the old one's farewell must not let the phone
    /// lock under the new one. Kept here, not on the model — every change to the model redraws
    /// every page alive under the player, and this changed on every pause.
    private static var awakeOwner: UUID?

    /// The screen stays awake while playback is wanted, not while a paused or failed picture
    /// sits there.
    private func awakeNow(_ on: Bool) {
        if on {
            PhonePlayer.awakeOwner = request.id
            UIApplication.shared.isIdleTimerDisabled = true
        } else if PhonePlayer.awakeOwner == request.id {
            PhonePlayer.awakeOwner = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: landscape

    /// The player that holds a phone in landscape, one at a time like the screen lock.
    private static var landscapeOwner: UUID?

    /// A film is wide: on a phone the player turns the screen to landscape while it is up, as
    /// the system's own player does. An iPad is left as it is held.
    private func holdLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        // which way the phone is held, for the way back (counted: begin here, end on release)
        if PhonePlayer.landscapeOwner == nil { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        PhonePlayer.landscapeOwner = request.id
        PhoneDelegate.held = .landscape
        PhonePlayer.turn(to: .landscape)
    }

    /// Back to turning freely once the player is gone — upright, unless the phone is still held
    /// on its side.
    private func releaseLandscape() {
        guard PhonePlayer.landscapeOwner == request.id else { return }
        PhonePlayer.landscapeOwner = nil
        PhoneDelegate.held = nil
        PhonePlayer.turn(to: UIDevice.current.orientation.isLandscape ? nil : .portrait)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private static func turn(to mask: UIInterfaceOrientationMask?) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // asked again what the app supports (PhoneDelegate), then turned
            for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            if let m = mask {
                scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: m)) { _ in }
            }
        }
    }

    // MARK: sound

    /// A call or an alarm takes the sound: pause, and play on afterwards only if iOS says to.
    private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = !mpv.paused
            mpv.setPaused(true)
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if resumeAfterInterruption && opts.contains(.shouldResume) {
                Audio.begin()
                mpv.setPaused(false)
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    /// Headphones pulled out: the film stops rather than carrying on out of the speaker.
    private func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        mpv.setPaused(true)
        wake()
    }

    // MARK: picture gestures

    private func tapZone(back: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if skip(forward: !back) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
            .onTapGesture {
                if locked { show(flash: "Locked"); return }
                withAnimation(.easeOut(duration: 0.2)) { chromeVisible.toggle() }
                if chromeVisible { wake() } else { hideTask?.cancel() }
            }
    }

    /// A step back or forward — a double tap on either half, or a keyboard's arrows. False when
    /// there was nowhere to go (locked, or a live stream already at its edge).
    @discardableResult
    private func skip(forward: Bool) -> Bool {
        guard !locked, forward ? mpv.canStepForward : mpv.canStepBack else { return false }
        mpv.seek(by: forward ? step : -step)
        show(flash: (forward ? "+" : "−") + "\(Int(step))s")
        wake()
        return true
    }

    /// Play or pause — the centre button and a keyboard's Space. At the end of a file it plays
    /// again from the top; at the end of a live stream it reconnects.
    private func playPause() {
        if mpv.ended && mpv.isLive { retry() }
        else if mpv.ended { mpv.seek(to: 0); mpv.setPaused(false) }
        else { mpv.togglePause() }
    }

    /// A keyboard on an iPad (or a phone): Space plays and pauses, ← → skip, Esc closes. A
    /// shortcut has to belong to a control, so these are buttons nobody sees.
    private var keyboardKeys: some View {
        ZStack {
            Button("Play or pause") { playPause(); wake() }.keyboardShortcut(.space, modifiers: [])
            Button("Back") { skip(forward: false) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward") { skip(forward: true) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Close") { close() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func flashLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    private func show(flash text: String) {
        withAnimation(.easeOut(duration: 0.12)) { flash = text }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { flash = nil } }
        }
    }

    // MARK: chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                GlassCircle(icon: "chevron.down", label: "Close", size: 38) { close() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).scaledFont(size: 16, weight: .semibold).foregroundStyle(.white).lineLimit(1)
                    if let k = request.kicker { Text(k).scaledFont(size: 12).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                    if !sourceLine.isEmpty {
                        Text(sourceLine).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                Spacer(minLength: 8)
                GlassCircle(icon: "lock.open", label: "Lock the screen", size: 38) { locked = true; hideTask?.cancel() }
            }
            // inside the safe area now, so only a small margin of its own (it was 52 points down
            // from the very top, which put it under the Dynamic Island in portrait)
            .padding(.horizontal, 12).padding(.top, 8)

            Spacer()

            HStack(spacing: 40) {
                GlassCircle(icon: "gobackward.\(stepIcon)", label: "Back \(model.prefs.seekStep) seconds", size: 52) { mpv.seek(by: -step); wake() }
                    .opacity(mpv.canStepBack ? 1 : 0.3)
                GlassCircle(icon: mpv.ended ? "arrow.counterclockwise" : mpv.paused ? "play.fill" : "pause.fill",
                            label: mpv.paused ? "Play" : "Pause", size: 76) {
                    playPause()
                    wake()
                }
                GlassCircle(icon: "goforward.\(stepIcon)", label: "Forward \(model.prefs.seekStep) seconds", size: 52) { mpv.seek(by: step); wake() }
                    .opacity(mpv.canStepForward ? 1 : 0.3)
            }
            .opacity(mpv.failure == nil ? 1 : 0)
            .allowsHitTesting(mpv.failure == nil)

            Spacer()

            VStack(spacing: 10) {
                scrubber
                HStack(spacing: 8) {
                    barButton("captions.bubble", "Subtitles", .subtitles)
                    barButton("waveform", "Audio", .audio)
                    Spacer()
                    barButton("speedometer", "Speed", .speed)
                    barButton("info.circle", "Info", .info)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        // the shade behind the controls still runs to the screen's edges
        .background(
            LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.26),
                                   .init(color: .clear, location: 0.58), .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
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

    private func barButton(_ icon: String, _ label: String, _ s: PlayerSheet) -> some View {
        GlassCircle(icon: icon, label: label, size: 40) { sheet = s; wake() }
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            if mpv.isLive {
                TimePill(text: "LIVE", live: true, accent: model.accent)
                Capsule().fill(.white.opacity(0.25)).frame(height: 6)
            } else {
                TimePill(text: Fmt.clock(scrubbing ?? mpv.timePos))
                Scrubber(position: scrubbing ?? mpv.timePos, duration: mpv.duration,
                         buffered: mpv.timePos + mpv.cacheAhead, accent: model.accent,
                         onDrag: { scrubbing = $0; wake() },
                         onCommit: { mpv.seek(to: $0); scrubbing = nil; wake() })
                TimePill(text: "−" + Fmt.clock(max(0, mpv.duration - (scrubbing ?? mpv.timePos))))
            }
        }
    }

    /// Locked, the picture takes no taps at all — the one control left unlocks it.
    private var lockPill: some View {
        VStack {
            HStack {
                Spacer()
                GlassCircle(icon: "lock.fill", label: "Unlock", size: 44) { locked = false; wake() }
                    .padding(.trailing, 12).padding(.top, 8)
            }
            Spacer()
        }
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let v = mpv.tracks.first(where: { $0.type == "video" && $0.selected }) {
            rows.append(("Picture", "\(v.codec.uppercased()) \(mpv.videoHeight > 0 ? "\(mpv.videoHeight)p" : "")"))
        }
        if let a = mpv.tracks.first(where: { $0.type == "audio" && $0.selected }) {
            rows.append(("Sound", "\(a.codec.uppercased())\(a.channels > 0 ? " · \(a.channels) ch" : "")"))
        }
        rows.append(("Decoding", mpv.hwdec.isEmpty || mpv.hwdec == "no" ? "On the processor" : "On the graphics chip"))
        rows.append(("Buffered", "\(Int(mpv.cacheAhead)) s ahead"))
        if !request.stream.clearKeys.isEmpty || protected { rows.append(("Protected", "Yes")) }
        if let h = URL(string: request.stream.url)?.host { rows.append(("From", h)) }
        return rows
    }

    private func failureCard(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.8))
            Text(text).scaledFont(size: 15, weight: .medium).foregroundStyle(.white).multilineTextAlignment(.center)
            // side by side when they fit; one above the other at a large text size
            ViewThatFits {
                HStack(spacing: 10) { failureActions }
                VStack(spacing: 10) { failureActions }
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var failureActions: some View {
        if resolved != nil { Button("Try again") { retry() }.buttonStyle(PillButtonStyle(filled: false)) }
        Button("Try another stream") { close() }.buttonStyle(PillButtonStyle())
    }

    private func nextPill(_ n: Episode) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: { playNext(n) }) {
                    HStack(spacing: 10) {
                        if nextBusy { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "forward.end.fill") }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Next episode").scaledFont(size: 13, weight: .semibold)
                            Text(Ids.episodeTag(n.id).map { "\($0) · \(n.name)" } ?? n.name)
                                .scaledFont(size: 11).opacity(0.7).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 52)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                    .environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                // above the scrubber and its buttons (98 points and their margin) while they show
                .padding(.bottom, chromeShown ? 118 : 12)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chromeShown)
    }

    // MARK: life cycle — the Mac's

    private func start() {
        guard sourceTask == nil, !finished, model.player?.id == request.id else { return }
        // PhoneRoot takes the session when a player opens; asking again here is harmless and
        // makes sure the session is up before the engine opens its output
        Audio.begin()
        // started with the phone locked (the next episode, rolling on in a pocket): sound only,
        // as if it had gone to the background while playing — the GPU may not draw back there
        if UIApplication.shared.applicationState == .background { mpv.setVideo(false) }
        let t = request.target
        nowPlaying.start(id: request.id, mpv: mpv, title: request.kicker ?? request.title, subtitle: request.kicker == nil ? nil : request.title,
                         step: step, art: t.episode?.thumbnail ?? t.item.background ?? t.item.poster)
        // an onChange does not fire for the value a view starts with, and this one starts true
        awakeNow(wantsAwake)
        holdLandscape()
        let s = request.stream
        sourceTask = Task {
            let got = await PlaybackRules.source(for: s, maxHeight: model.prefs.maxHeight, stremio: model.stremio)
            guard !Task.isCancelled, !finished, model.player?.id == request.id else { ManifestProxy.shared.release(got.token); return }
            manifestToken = got.token
            protected = !got.keys.isEmpty
            resolved = got.address; resolvedKeys = got.keys
            mpv.load(url: got.address, startAt: request.startAt, keys: got.keys, headers: s.headers)
        }
        subtitleTask = Task {
            let t = request.target
            let subs = await model.addonSubtitles(type: t.type, id: t.id)
            guard !Task.isCancelled, !finished, model.player?.id == request.id else { return }
            if captions.addonsAnswered(subs) { attachSubs() }
        }
        wake()
    }

    private func loadedNow() {
        guard !finished, model.player?.id == request.id else { return }
        if UIApplication.shared.applicationState == .background { mpv.setVideo(false) }
        if !captions.handPicked { PlaybackRules.selectSubtitles(want: model.prefs.subLang, chosen: model.prefs.hasSubLang, to: mpv) }
        if captions.fileLoaded() { attachSubs() }
        let want = Lang.key(model.prefs.audioLang)
        if !want.isEmpty, let t = mpv.tracks.first(where: { $0.type == "audio" && Lang.key($0.lang) == want }), !t.selected {
            mpv.selectTrack("audio", id: t.id)
        }
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
        guard !finished, model.player?.id == request.id else { return }
        guard !mpv.isLive else { mpv.failure = PlaybackRules.liveStopped; return }
        guard PlaybackRules.reachedTheEnd(pos: mpv.timePos, dur: mpv.duration) else {
            // the connection went, not the film: keep the place and say so
            save()
            mpv.failure = PlaybackRules.cutShort
            return
        }
        model.progress.note(PlaybackRules.doneRecord(target: request.target))
        if let n = next, model.prefs.autoplayNext { playNext(n) }
    }

    private func playNext(_ n: Episode) {
        guard !nextBusy, !finished, model.player?.id == request.id else { return }
        nextBusy = true
        var target = request.target
        target.id = n.id
        target.episode = n
        let group = request.stream.bingeGroup, origin = request.streamAddon
        nextTask = Task {
            let found = await PlaybackRules.nextStream(origin: origin, type: target.type, id: n.id, bingeGroup: group, stremio: model.stremio)
            guard !Task.isCancelled, !finished, model.player?.id == request.id else { return }
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

    /// The same stream again, from where it stopped (a live one from its edge). The source is
    /// resolved afresh, not replayed: protected DASH plays through the loopback manifest cache,
    /// and the address handed out before may name a port that listener has since given up.
    private func retry() {
        guard resolved != nil, !retrying, !finished, model.player?.id == request.id else { return }
        let at = mpv.isLive ? 0 : max(0, mpv.timePos - 2)
        retrying = true
        mpv.failure = nil; mpv.buffering = true
        captions.reopened()
        let s = request.stream
        sourceTask?.cancel()
        sourceTask = Task {
            let got = await PlaybackRules.source(for: s, maxHeight: model.prefs.maxHeight, stremio: model.stremio)
            guard !Task.isCancelled, !finished, model.player?.id == request.id else { ManifestProxy.shared.release(got.token); return }
            ManifestProxy.shared.release(manifestToken)
            manifestToken = got.token
            let keys = got.keys.isEmpty ? resolvedKeys : got.keys     // a licence that did not answer this time
            resolved = got.address; resolvedKeys = keys
            retrying = false
            mpv.load(url: got.address, startAt: at, keys: keys, headers: s.headers)
        }
        wake()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        sourceTask?.cancel(); subtitleTask?.cancel(); nextTask?.cancel()
        ManifestProxy.shared.release(manifestToken)
        manifestToken = nil
        save()
        hideTask?.cancel()
        flashTask?.cancel()
        nowPlaying.finish()
        awakeNow(false)
        // the screen turns back only when no other player has taken it over (the next episode's
        // appears before this one is gone, and keeps it in landscape)
        if model.player == nil || model.player?.id == request.id { releaseLandscape() }
        // the sound goes back once the engine has let go of its output, so the music the viewer
        // had on is told to go on — unless another player has taken the screen meanwhile
        let m = model
        mpv.close { if m.player == nil { Audio.end() } }
        Task { await model.cloud.flush() }
    }

    private func close() {
        guard model.player?.id == request.id else { return }
        finish()
        model.player = nil
    }

    /// Show the chrome, then let it go after three quiet seconds. A sheet, a pause or a failure
    /// keeps it up — nothing should vanish under a finger that is still deciding.
    private func wake() {
        guard !finished, model.player?.id == request.id else { return }
        if !chromeVisible { withAnimation(.easeOut(duration: 0.2)) { chromeVisible = true } }
        hideTask?.cancel()
        // the screenshot rig needs the controls to stay up; nothing else sets this
        if ProcessInfo.processInfo.environment["NEBULA_KEEP_CHROME"] == "1" { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled || mpv.paused || sheet != nil || mpv.failure != nil { return }
            withAnimation(.easeOut(duration: 0.25)) { chromeVisible = false }
        }
    }
}

/// The engine's Metal layer, kept the size of the view in real pixels. A phone cannot swap a
/// view's backing layer the way AppKit can, so the engine's layer rides as a sublayer.
final class VideoHostView: UIView {
    let metal: MetalLayer

    init(layer: MetalLayer) {
        metal = layer
        super.init(frame: .zero)
        backgroundColor = .black
        metal.backgroundColor = UIColor.black.cgColor
        metal.framebufferOnly = true
        self.layer.addSublayer(metal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // no implicit animation: the layer must follow a rotation exactly, not slide into place
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }
}

struct PhoneVideoSurface: UIViewRepresentable {
    let controller: MPVController
    func makeUIView(context: Context) -> VideoHostView { VideoHostView(layer: controller.layer) }
    func updateUIView(_ uiView: VideoHostView, context: Context) {}
}

/// Audio, subtitles, speed and info as a sheet — where a phone expects a list it can scroll.
@MainActor
struct PlayerSheetView: View {
    let kind: PhonePlayer.PlayerSheet
    @ObservedObject var mpv: MPVController
    let subsAdded: Bool
    let infoRows: [(String, String)]
    let prefs: Prefs
    let onSubtitlePick: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .audio:
                    let list = mpv.tracks.filter { $0.type == "audio" }
                    if list.isEmpty { note("This stream has one soundtrack.") }
                    ForEach(list) { t in
                        row(t.label, on: t.selected) { mpv.selectTrack("audio", id: t.id); prefs.audioLang = Lang.key(t.lang) }
                    }
                case .subtitles:
                    let list = mpv.tracks.filter { $0.type == "sub" }
                    row("Off", on: !list.contains { $0.selected }) { onSubtitlePick(); mpv.selectTrack("sub", id: nil); prefs.subLang = "" }
                    ForEach(list) { t in
                        row(t.label + (t.external ? "" : " · in the file"), on: t.selected) {
                            onSubtitlePick(); mpv.selectTrack("sub", id: t.id); prefs.subLang = Lang.key(t.lang)
                        }
                    }
                    if list.isEmpty { note(subsAdded ? "No subtitles were found for this." : "Looking for subtitles…") }
                case .speed:
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                        row(s == 1 ? "Normal" : String(format: "%g×", s), on: abs(mpv.speed - s) < 0.01) { mpv.setSpeed(s) }
                    }
                case .info:
                    ForEach(infoRows, id: \.0) { r in
                        HStack {
                            Text(r.0).foregroundStyle(Theme.label2)
                            Spacer(minLength: 20)
                            Text(r.1).foregroundStyle(Theme.ink)
                        }
                        .scaledFont(size: 13, design: .monospaced)
                        .listRowBackground(Theme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var title: String {
        switch kind {
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        case .speed: return "Speed"
        case .info: return "Info"
        }
    }

    private func row(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).scaledFont(size: 15, weight: on ? .semibold : .regular).foregroundStyle(Theme.ink)
                Spacer()
                if on { Image(systemName: "checkmark").scaledFont(size: 13, weight: .bold) }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Theme.surface)
    }

    private func note(_ t: String) -> some View {
        Text(t).scaledFont(size: 13).foregroundStyle(Theme.label2).listRowBackground(Theme.surface)
    }
}
