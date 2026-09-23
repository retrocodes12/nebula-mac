import Foundation
import Combine
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// The system's Now Playing card and its remote commands: the lock screen, Control Center and
/// the headphones' own buttons on a phone; the play/pause key, AirPods and Control Center on a
/// Mac. Without it a Mac's media keys went to Music (and started it over the film), and a locked
/// phone played on with no way to pause short of unlocking it.
///
/// The engine's own media-key handling stays off (`input-media-keys=no`): the system routes
/// those keys through the command center, to whichever app says it is playing.
///
/// One player owns it at a time. The next episode's player appears before the old one has gone,
/// so the old one's finish removes only its own command targets and leaves the new one's card.
@MainActor
final class NowPlaying {
    private static var owner: UUID?
    private var id: UUID?
    private weak var mpv: MPVController?
    private var title = ""
    private var subtitle: String?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    /// The engine's published values, watched directly: a SwiftUI `onChange` is not known to
    /// run while a phone is locked, and that is exactly when the card is looked at.
    private var watch: AnyCancellable?
    /// What the card said last, so it is only rewritten when the system's own clock would be wrong.
    private var last: (at: Date, elapsed: Double, rate: Double, duration: Double, live: Bool, art: Bool, ended: Bool, steps: [Bool])?

    nonisolated init() {}

    private var commands: [MPRemoteCommand] {
        let c = MPRemoteCommandCenter.shared()
        return [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.changePlaybackPositionCommand,
                c.skipForwardCommand, c.skipBackwardCommand]
    }

    func start(id: UUID, mpv: MPVController, title: String, subtitle: String?, step: Double, art: String?) {
        // started twice, every handler would run twice — and a toggle pressed twice does nothing
        guard targets.isEmpty, self.id == nil else { return }
        self.id = id
        self.mpv = mpv
        self.title = title
        self.subtitle = subtitle
        NowPlaying.owner = id
        let c = MPRemoteCommandCenter.shared()
        // the handlers touch only the engine, whose calls are safe from any thread
        on(c.playCommand) { [weak mpv] _ in mpv?.setPaused(false); return .success }
        on(c.pauseCommand) { [weak mpv] _ in mpv?.setPaused(true); return .success }
        on(c.togglePlayPauseCommand) { [weak mpv] _ in mpv?.togglePause(); return .success }
        on(c.changePlaybackPositionCommand) { [weak mpv] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            mpv?.seek(to: e.positionTime)
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: step)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: step)]
        on(c.skipForwardCommand) { [weak mpv] _ in mpv?.seek(by: step); return .success }
        on(c.skipBackwardCommand) { [weak mpv] _ in mpv?.seek(by: -step); return .success }

        // every change the engine publishes (on the main queue) — delivered a turn later, once
        // the new value is in place: @Published announces a change before it makes it
        watch = mpv.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }

        if let a = art, !a.isEmpty {
            Task { [weak self] in
                guard let img = await ImageLoader.shared.load(a), let self = self, NowPlaying.owner == id else { return }
                self.artwork = NowPlaying.artwork(img)
                self.refresh()
            }
        }
    }

    /// Made outside the main actor: the system asks for the picture from a thread of its own,
    /// and a closure formed in here would carry the main actor's isolation with it.
    nonisolated private static func artwork(_ img: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func on(_ cmd: MPRemoteCommand, _ handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        cmd.isEnabled = true
        targets.append((cmd, cmd.addTarget(handler: handler)))
    }

    /// Runs whenever the engine changes. The system runs the elapsed time on by itself from the
    /// rate, so the card is rewritten only when that would be wrong — a pause, a seek, a new
    /// length, the end, the art arriving — and at most every 15 s otherwise.
    func refresh() {
        guard let id = id, NowPlaying.owner == id, let mpv = mpv, mpv.loaded else { return }
        let live = mpv.isLive
        let rate = mpv.paused || mpv.ended || mpv.failure != nil ? 0 : mpv.speed
        let elapsed = mpv.timePos.isFinite ? max(0, mpv.timePos) : 0
        let now = Date()
        let steps = [mpv.canStepBack, mpv.canStepForward]
        if let l = last, l.rate == rate, l.duration == mpv.duration, l.live == live, l.art == (artwork != nil),
           l.ended == mpv.ended, l.steps == steps,
           now.timeIntervalSince(l.at) < 15, abs(l.elapsed + now.timeIntervalSince(l.at) * l.rate - elapsed) < 2 {
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: live,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let s = subtitle { info[MPMediaItemPropertyArtist] = s }
        if !live {
            info[MPMediaItemPropertyPlaybackDuration] = mpv.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        if let a = artwork { info[MPMediaItemPropertyArtwork] = a }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        // a Mac hands the media keys to the app whose state says it is playing, not to the one
        // that merely has a card up
        center.playbackState = rate > 0 ? .playing : mpv.ended ? .stopped : .paused
        #endif
        let c = MPRemoteCommandCenter.shared()
        // a live stream has no length to scrub along; it steps back only inside the window the
        // engine says it can seek in, and forward only as far as it was stepped back
        c.changePlaybackPositionCommand.isEnabled = !live
        c.skipBackwardCommand.isEnabled = steps[0]
        c.skipForwardCommand.isEnabled = steps[1]
        last = (now, elapsed, rate, mpv.duration, live, artwork != nil, mpv.ended, steps)
    }

    func finish() {
        watch?.cancel()
        watch = nil
        for (cmd, t) in targets { cmd.removeTarget(t) }
        targets = []
        guard let id = id, NowPlaying.owner == id else { return }
        NowPlaying.owner = nil
        let center = MPNowPlayingInfoCenter.default()
        #if os(macOS)
        center.playbackState = .stopped
        #endif
        center.nowPlayingInfo = nil
        for cmd in commands { cmd.isEnabled = false }
    }
}
