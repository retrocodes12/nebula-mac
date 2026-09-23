import Foundation
import UIKit
import MediaPlayer

/// The lock screen, Control Center and the headphones' own buttons. The app keeps playing with
/// the phone locked (its audio session says so); without this the viewer heard the film but
/// could not pause it short of unlocking the phone, and AirPods' squeeze did nothing.
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
    /// What the card said last, so it is only rewritten when the system's own clock would be wrong.
    private var last: (at: Date, elapsed: Double, rate: Double, duration: Double, live: Bool, art: Bool)?

    nonisolated init() {}

    private var commands: [MPRemoteCommand] {
        let c = MPRemoteCommandCenter.shared()
        return [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.changePlaybackPositionCommand,
                c.skipForwardCommand, c.skipBackwardCommand]
    }

    func start(id: UUID, mpv: MPVController, title: String, subtitle: String?, step: Double, art: String?) {
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

        if let a = art, !a.isEmpty {
            Task { [weak self] in
                guard let img = await ImageLoader.shared.load(a), let self = self, NowPlaying.owner == id else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.refresh()
            }
        }
    }

    private func on(_ cmd: MPRemoteCommand, _ handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        cmd.isEnabled = true
        targets.append((cmd, cmd.addTarget(handler: handler)))
    }

    /// Called as the engine's clock moves and whenever it starts or stops. The system runs the
    /// elapsed time on by itself from the rate, so the card is rewritten only when that would
    /// be wrong — a pause, a seek, a new length, the art arriving — and at most every 15 s.
    func refresh() {
        guard let id = id, NowPlaying.owner == id, let mpv = mpv, mpv.loaded else { return }
        let live = mpv.isLive
        let rate = mpv.paused || mpv.ended || mpv.failure != nil ? 0 : mpv.speed
        let elapsed = mpv.timePos.isFinite ? max(0, mpv.timePos) : 0
        let now = Date()
        if let l = last, l.rate == rate, l.duration == mpv.duration, l.live == live, l.art == (artwork != nil),
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let c = MPRemoteCommandCenter.shared()
        c.changePlaybackPositionCommand.isEnabled = !live
        c.skipForwardCommand.isEnabled = !live
        c.skipBackwardCommand.isEnabled = !live || mpv.seekable
        last = (now, elapsed, rate, mpv.duration, live, artwork != nil)
    }

    func finish() {
        for (cmd, t) in targets { cmd.removeTarget(t) }
        targets = []
        guard let id = id, NowPlaying.owner == id else { return }
        NowPlaying.owner = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for cmd in commands { cmd.isEnabled = false }
    }
}
