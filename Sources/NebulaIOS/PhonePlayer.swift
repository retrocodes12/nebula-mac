import SwiftUI
import UIKit
import NebulaCore

/// The phone's player. The engine, the source resolution, the captions, the resume point and the
/// next episode are `PlaybackRules` — the same ones the Mac uses. What is written here is only
/// what a finger needs: tap to wake, double tap a side to skip, drag the scrubber, and sheets
/// instead of the window's hovering panels.
struct PhonePlayer: View {
    @EnvironmentObject var model: AppModel
    let request: PlayRequest
    @StateObject private var mpv: MPVController
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var sheet: PlayerSheet?
    @State private var scrubbing: Double?
    @State private var addonSubs: [SubTrack] = []
    @State private var subsAdded = false
    @State private var nextOffered = false
    @State private var nextBusy = false
    @State private var lastSaved: Double = -100
    @State private var protected = false
    @State private var locked = false
    @State private var flash: String?
    @State private var flashTask: Task<Void, Never>?

    enum PlayerSheet: String, Identifiable { case audio, subtitles, speed, info; var id: String { rawValue } }

    init(request: PlayRequest, hardwareDecoding: Bool) {
        self.request = request
        _mpv = StateObject(wrappedValue: MPVController(hardwareDecoding: hardwareDecoding))
    }

    var next: Episode? { model.nextEpisode(after: request.target) }
    private var chromeShown: Bool { !locked && (chromeVisible || mpv.paused || mpv.failure != nil) }
    private var step: Double { Double(model.prefs.seekStep) }

    var body: some View {
        ZStack {
            Color.black
            PhoneVideoSurface(controller: mpv)

            // the picture is two halves: one tap wakes the chrome, two skip a step
            HStack(spacing: 0) {
                tapZone(back: true)
                tapZone(back: false)
            }

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
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $sheet) { s in
            PlayerSheetView(kind: s, mpv: mpv, subsAdded: subsAdded, infoRows: infoRows, prefs: model.prefs)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .onAppear(perform: start)
        .onDisappear(perform: finish)
        .onChange(of: mpv.timePos) { t in tick(t) }
        .onChange(of: mpv.ended) { e in if e { reachedEnd() } }
        .onChange(of: mpv.loaded) { l in if l { loadedNow() } }
        // the hide timer stands down while a sheet is up, so closing one has to re-arm it or the
        // chrome sits there for good
        .onChange(of: sheet) { s in if s == nil { wake() } }
    }

    // MARK: picture gestures

    private func tapZone(back: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !locked, !(mpv.isLive && !mpv.seekable) else { return }
                if back && mpv.isLive { return }
                mpv.seek(by: back ? -step : step)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                show(flash: (back ? "−" : "+") + "\(Int(step))s")
                wake()
            }
            .onTapGesture {
                if locked { show(flash: "Locked"); return }
                withAnimation(.easeOut(duration: 0.2)) { chromeVisible.toggle() }
                if chromeVisible { wake() } else { hideTask?.cancel() }
            }
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
                    Text(request.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let k = request.kicker { Text(k).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                    if !sourceLine.isEmpty {
                        Text(sourceLine).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                Spacer(minLength: 8)
                GlassCircle(icon: "lock.open", label: "Lock the screen", size: 38) { locked = true; hideTask?.cancel() }
            }
            .padding(.horizontal, 16).padding(.top, 52)

            Spacer()

            HStack(spacing: 40) {
                GlassCircle(icon: "gobackward.\(stepIcon)", label: "Back \(model.prefs.seekStep) seconds", size: 52) { mpv.seek(by: -step); wake() }
                    .opacity(mpv.isLive && !mpv.seekable ? 0.3 : 1)
                GlassCircle(icon: mpv.ended ? "arrow.counterclockwise" : mpv.paused ? "play.fill" : "pause.fill",
                            label: mpv.paused ? "Play" : "Pause", size: 76) {
                    if mpv.ended { mpv.seek(to: 0); mpv.setPaused(false) } else { mpv.togglePause() }
                    wake()
                }
                GlassCircle(icon: "goforward.\(stepIcon)", label: "Forward \(model.prefs.seekStep) seconds", size: 52) { mpv.seek(by: step); wake() }
                    .opacity(mpv.isLive ? 0.3 : 1)
            }
            .opacity(mpv.failure == nil ? 1 : 0)

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
            .padding(.horizontal, 16).padding(.bottom, 34)
        }
        .background(
            LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.26),
                                   .init(color: .clear, location: 0.58), .init(color: .black.opacity(0.75), location: 1)],
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

    private func barButton(_ icon: String, _ label: String, _ s: PlayerSheet) -> some View {
        GlassCircle(icon: icon, label: label, size: 40) { sheet = s; wake() }
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            if mpv.isLive {
                TimePill(text: "LIVE", live: true)
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
                    .padding(.trailing, 16).padding(.top, 52)
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
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.center)
            Button("Try another stream") { close() }.buttonStyle(PillButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 24)
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
                            Text("Next episode").font(.system(size: 13, weight: .semibold))
                            Text(Ids.episodeTag(n.id).map { "\($0) · \(n.name)" } ?? n.name)
                                .font(.system(size: 11)).opacity(0.7).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 52)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                    .environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.bottom, chromeShown ? 150 : 46)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chromeShown)
    }

    // MARK: life cycle — the Mac's, with the phone's idle timer added

    private func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        Audio.begin()
        let s = request.stream
        Task {
            let got = await PlaybackRules.source(for: s, maxHeight: model.prefs.maxHeight, stremio: model.stremio)
            protected = !got.keys.isEmpty
            mpv.load(url: got.address, startAt: request.startAt, keys: got.keys, headers: s.headers)
        }
        Task {
            let t = request.target
            addonSubs = await model.addonSubtitles(type: t.type, id: t.id)
            attachSubs()
        }
        wake()
    }

    private func loadedNow() {
        attachSubs()
        let want = model.prefs.audioLang
        if !want.isEmpty, let t = mpv.tracks.first(where: { $0.type == "audio" && $0.lang == want }), !t.selected {
            mpv.selectTrack("audio", id: t.id)
        }
    }

    private func attachSubs() {
        guard mpv.loaded, !subsAdded else { return }
        let want = model.prefs.subLang
        let plan = PlaybackRules.subtitlePlan(stream: request.stream, addon: addonSubs, want: want)
        if plan.isEmpty { subsAdded = true; return }
        subsAdded = true
        for p in plan { mpv.addSubtitle(url: p.url, lang: p.lang, title: p.title, select: p.select) }
        if want.isEmpty { mpv.selectTrack("sub", id: nil) }
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
        model.progress.note(PlaybackRules.doneRecord(target: request.target))
        if let n = next, model.prefs.autoplayNext { playNext(n) }
    }

    private func playNext(_ n: Episode) {
        guard !nextBusy else { return }
        nextBusy = true
        var target = request.target
        target.id = n.id
        target.episode = n
        let group = request.stream.bingeGroup, origin = request.streamAddon
        Task {
            let found = await PlaybackRules.nextStream(origin: origin, type: target.type, id: n.id, bingeGroup: group, stremio: model.stremio)
            nextBusy = false
            if let f = found {
                save()
                model.play(f.0, target: target, from: f.1, fresh: true)
            } else {
                close()
                model.path.append(.streams(target))
            }
        }
    }

    private func finish() {
        save()
        hideTask?.cancel()
        flashTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        mpv.close()
        Task { await model.cloud.flush() }
    }

    private func close() { model.player = nil }

    /// Show the chrome, then let it go after three quiet seconds. A sheet, a pause or a failure
    /// keeps it up — nothing should vanish under a finger that is still deciding.
    private func wake() {
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
struct PlayerSheetView: View {
    let kind: PhonePlayer.PlayerSheet
    @ObservedObject var mpv: MPVController
    let subsAdded: Bool
    let infoRows: [(String, String)]
    let prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .audio:
                    let list = mpv.tracks.filter { $0.type == "audio" }
                    if list.isEmpty { note("This stream has one soundtrack.") }
                    ForEach(list) { t in
                        row(t.label, on: t.selected) { mpv.selectTrack("audio", id: t.id); prefs.audioLang = t.lang }
                    }
                case .subtitles:
                    let list = mpv.tracks.filter { $0.type == "sub" }
                    row("Off", on: !list.contains { $0.selected }) { mpv.selectTrack("sub", id: nil); prefs.subLang = "" }
                    ForEach(list) { t in
                        row(t.label + (t.external ? "" : " · in the file"), on: t.selected) {
                            mpv.selectTrack("sub", id: t.id); prefs.subLang = t.lang
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
                        .font(.system(size: 13, design: .monospaced))
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
                Text(text).font(.system(size: 15, weight: on ? .semibold : .regular)).foregroundStyle(Theme.ink)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Theme.surface)
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundStyle(Theme.label2).listRowBackground(Theme.surface)
    }
}
