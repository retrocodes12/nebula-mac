import SwiftUI
import NebulaCore

/// The launch card (Android's AutoplayCardHost): the title over its backdrop, who is being asked, then what starts —
/// full screen, over the list and then over the player until its first picture. A tap sends it away and goes no
/// further: it would otherwise land on a row of the list or the player's controls underneath.
struct AutoplayCardHost: View {
    @ObservedObject var run = AutoplayRun.shared

    var body: some View {
        ZStack {
            if let c = run.card { card(c) }
        }
        .animation(.easeOut(duration: 0.25), value: run.card == nil)
    }

    private func card(_ c: ApCard) -> some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 600
            ZStack(alignment: .bottomLeading) {
                // the art and its shade run under the status bar, the notch and the home indicator; the words do not
                ZStack {
                    Theme.bg
                    RemoteImage(url: c.art) { Theme.bg }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    LinearGradient(stops: [.init(color: .black.opacity(0.95), location: 0), .init(color: .black.opacity(0.55), location: 0.55),
                                           .init(color: .black.opacity(0.2), location: 1)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.9), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    ApTitle(card: c, narrow: narrow)
                    if let s = c.sub {
                        Text(s).scaledFont(size: 17).foregroundStyle(.white.opacity(0.72)).lineLimit(1).padding(.top, 8)
                    }
                    HStack(spacing: 12) {
                        ProgressView().tint(.white).controlSize(.small)
                        Text(c.line).scaledFont(size: 18, weight: .semibold).foregroundStyle(.white).lineLimit(2)
                    }
                    .padding(.top, 22)
                    if !c.chips.isEmpty {
                        let shown = narrow ? 3 : 6
                        HStack(spacing: 8) {
                            ForEach(Array(c.chips.prefix(shown).enumerated()), id: \.offset) { _, ch in ApChipView(chip: ch) }
                            if c.chips.count > shown {
                                Text("+\(c.chips.count - shown)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.label2)
                            }
                        }
                        .padding(.top, 16)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, narrow ? 24 : 64).padding(.bottom, narrow ? 40 : 56)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { run.dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the list of streams")
        .transition(.opacity)
    }
}

/// The title's wordmark when it has a wide one (a square badge reads worse than the title in type), else the title.
private struct ApTitle: View {
    let card: ApCard
    let narrow: Bool
    @State private var logo: PlatformImage?

    var body: some View {
        Group {
            if let img = logo {
                Image(platform: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: narrow ? 300 : 460, maxHeight: narrow ? 72 : 110, alignment: .bottomLeading)
                    .accessibilityLabel(card.title)
            } else {
                Text(card.title).scaledFont(size: narrow ? 30 : 40, weight: .bold).foregroundStyle(.white).lineLimit(2)
            }
        }
        .task(id: card.logo) {
            logo = nil
            guard let u = card.logo, let img = await ImageLoader.shared.load(u) else { return }
            if img.size.height > 0 && img.size.width / img.size.height >= 1.6 { logo = img }
        }
    }
}

private struct ApChipView: View {
    let chip: ApChip

    var body: some View {
        HStack(spacing: 7) {
            // a dot that is lit while the add-on answers, solid once it has rows, hollow when it had none
            Circle().fill(chip.count == nil ? Color.white.opacity(0.6) : (chip.count ?? 0) > 0 ? Color.white : Color.clear)
                .overlay(Circle().strokeBorder(.white.opacity(0.4)))
                .frame(width: 7, height: 7)
            Text(chip.name).scaledFont(size: 13).foregroundStyle(chip.count == 0 ? Theme.label2 : Color.white).lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            if let n = chip.count {
                Text(n > 0 ? "\(n)" : "none").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.label2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .overlay(Capsule().strokeBorder(chip.count == nil ? Color.white.opacity(0.2) : Theme.line))
    }
}

/// Settings › Autoplay the best stream: the switch, and its six options while it is on (Android's group, word for word).
struct AutoplaySettings: View {
    @EnvironmentObject var model: AppModel
    /// The prefs are read where they are drawn (not copied when the page first appeared — every tab is alive from
    /// launch, so a copy went stale); a change bumps this to draw again.
    @State private var drawn = 0

    var body: some View {
        let _ = drawn
        let p = model.prefs
        Panel {
            PanelRow(title: "Autoplay the best stream", detail: "Play on a film or episode starts its best stream — no list") {
                Toggle("", isOn: bind(p.bestPlay) { p.bestPlay = $0 }).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if p.bestPlay {
                Hairline()
                chips("Aim for", "The best quality worth starting · higher ones come after it",
                      [(2160, "4K"), (1080, "1080p"), (720, "720p")], p.apMax) { p.apMax = $0 }
                Hairline()
                PanelRow(title: "Instant debrid first", detail: "Debrid rows that are ready play before higher quality") {
                    Toggle("", isOn: bind(p.apInstant) { p.apInstant = $0 }).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                Hairline()
                chips("Wait for add-ons", "Quick starts sooner · All waits for every add-on to answer",
                      [("quick", "Quick"), ("balanced", "Balanced"), ("all", "All")], p.apWait) { p.apWait = $0 }
                Hairline()
                chips("If it won't start", "Plays the next best stream instead",
                      [(0, "Off"), (3, "Next 3"), (5, "Next 5")], p.apRetry) { p.apRetry = $0 }
                Hairline()
                chips("Give a start", "How long a stream has to show its picture",
                      [(20, "20 s"), (45, "45 s"), (90, "90 s")], p.apStart) { p.apStart = $0 }
                Hairline()
                chips("Back from the player", "Where Back lands after a film started this way",
                      [("title", "Title page"), ("list", "Streams list")], p.apBack) { p.apBack = $0 }
            }
        }
    }

    private func bind(_ v: Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { v }, set: { set($0); drawn &+= 1 })
    }

    private func chips<V: Hashable>(_ title: String, _ detail: String, _ opts: [(V, String)], _ value: V,
                                    _ set: @escaping (V) -> Void) -> some View {
        PanelRow(title: title, detail: detail) {
            HStack(spacing: 6) {
                ForEach(opts, id: \.0) { o in Chip(text: o.1, on: value == o.0) { set(o.0); drawn &+= 1 } }
            }
        }
    }
}
