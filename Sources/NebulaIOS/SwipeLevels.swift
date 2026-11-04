import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

/// VLC's swipes on the phone's player: up/down on the left half = the screen's brightness (given back when the player
/// closes), on the right half = the system volume (through a hidden volume slider, which also keeps the system's own
/// volume pop-up off the picture). A three-quarter-height swipe covers the whole range. Android's SwipeLevels.kt, the same.
@MainActor
final class SwipeLevels: ObservableObject {
    enum Kind { case brightness, volume }

    /// What the bar shows: which level and where it is (0...1); nil when nothing is being swiped.
    @Published private(set) var shown: (kind: Kind, value: CGFloat)?

    private var kind: Kind?
    private var from: CGFloat = 0
    private var savedBrightness: CGFloat?
    private var hideTask: Task<Void, Never>?
    /// The hidden system slider (SystemVolumeView puts it in the window).
    weak var slider: UISlider?

    var active: Bool { kind != nil }

    func change(left: Bool, start: CGPoint, dy: CGFloat, height: CGFloat) {
        if kind == nil {
            let edge: CGFloat = 40                       // a swipe from the top or bottom edge stays the system's
            guard start.y > edge, start.y < height - edge else { return }
            kind = left ? .brightness : .volume
            from = level(kind!)
            hideTask?.cancel()
        }
        guard let k = kind else { return }
        let v = min(1, max(0, from - dy / (height * 0.75)))
        set(k, v)
        shown = (k, v)
    }

    func end() {
        guard kind != nil else { return }
        kind = nil
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.shown = nil
        }
    }

    /// The player is closing: the screen goes back to the brightness it had.
    func restore() {
        if let b = savedBrightness { UIScreen.main.brightness = b; savedBrightness = nil }
    }

    private func level(_ k: Kind) -> CGFloat {
        switch k {
        case .brightness: return UIScreen.main.brightness
        case .volume: return CGFloat(slider?.value ?? AVAudioSession.sharedInstance().outputVolume)
        }
    }

    private func set(_ k: Kind, _ v: CGFloat) {
        switch k {
        case .brightness:
            if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
            UIScreen.main.brightness = v
        case .volume:
            slider?.value = Float(v)
            slider?.sendActions(for: .valueChanged)
        }
    }
}

/// The system volume control, out of sight: its slider sets the phone's volume, and while it is on screen iOS shows no
/// volume pop-up of its own.
struct SystemVolumeView: UIViewRepresentable {
    let levels: SwipeLevels

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { levels.slider = v.subviews.compactMap { $0 as? UISlider }.first }
        return v
    }

    func updateUIView(_ v: MPVolumeView, context: Context) {
        if levels.slider == nil { levels.slider = v.subviews.compactMap { $0 as? UISlider }.first }
    }
}

/// The bar VLC shows while a level is swiped: an icon, a vertical track filled to the level, the percentage — on the
/// side being swiped.
struct SwipeLevelBar: View {
    @ObservedObject var levels: SwipeLevels

    var body: some View {
        if let s = levels.shown {
            HStack {
                if s.kind == .volume { Spacer() }
                VStack(spacing: 10) {
                    Image(systemName: s.kind == .brightness ? "sun.max.fill" : (s.value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"))
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).frame(height: 22)
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white).frame(height: 140 * s.value)
                    }
                    .frame(width: 6, height: 140)
                    Text("\(Int((s.value * 100).rounded()))").font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 14)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 48)
                if s.kind == .brightness { Spacer() }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
