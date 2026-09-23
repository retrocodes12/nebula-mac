import SwiftUI
import UIKit
import NebulaCore

/// The phone's shell. The Mac keeps a sidebar and its pages side by side; a phone puts the tabs
/// on a floating pill at the bottom and lets a pushed page cover them, which is the platform's
/// own habit. The page stack itself is the model's `path`, exactly as on the Mac — one stack,
/// one set of rules, so a title opened here behaves like a title opened there.
struct PhoneRoot: View {
    @EnvironmentObject var model: AppModel

    private var pushed: Bool { !model.path.isEmpty }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            // Every page is pinned to an EXACT screen-sized frame. A ZStack otherwise takes the
            // width of its widest child and centres the rest inside it, and these pages were
            // written for a window: one wide row in any of the five tabs — they are all alive at
            // once so a row keeps its place — stretched the whole stack and clipped every page,
            // the tab bar and the player (an overlay inherits the size) on both edges. An exact
            // frame reports its own size upwards, so no child can widen the stack any more.
            //
            // The status bar is measured here and handed down (`topBleed`): Home, a title page and
            // a streams page run their art up under it, edge to edge like the system's own apps,
            // so each page is clipped to its frame AND the strip above it — clipped to the frame
            // alone, the art stopped at the status bar with a hard edge.
            GeometryReader { geo in
                let top = PhoneRoot.statusBar(geo)
                ZStack(alignment: .topLeading) {
                    ForEach(Tab.allCases) { t in
                        tabRoot(t)
                            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 68) }
                            .environment(\.topBleed, top)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                            .clipShape(UnderStatusBar(top: top))
                            .opacity(model.tab == t && !pushed ? 1 : 0)
                            .allowsHitTesting(model.tab == t && !pushed)
                    }
                    ForEach(Array(model.path.enumerated()), id: \.offset) { i, route in
                        // keyed by place in the stack (the same page can sit in it twice, apart),
                        // and by the page itself, so a new page in an old place starts fresh
                        page(route)
                            .id(route)
                            .environment(\.topBleed, top)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                            .clipShape(UnderStatusBar(top: top))
                            .background(Theme.bg)
                            .opacity(i == model.path.count - 1 ? 1 : 0)
                            .allowsHitTesting(i == model.path.count - 1)
                    }
                    // a soft shade under the status bar, so its clock reads over bright art and
                    // over whatever scrolls up beneath it — no line where the art begins (none in
                    // landscape, where a phone shows no status bar)
                    if top > 0 {
                        LinearGradient(stops: [.init(color: Theme.bg.opacity(0.72), location: 0),
                                               .init(color: Theme.bg.opacity(0.38), location: 0.55),
                                               .init(color: Theme.bg.opacity(0), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(width: geo.size.width, height: top + 30)
                            .offset(y: -top)
                            .allowsHitTesting(false)
                    }
                }
            }

            if !pushed {
                VStack { Spacer(); TabPill() }
                    .transition(.opacity)
            }

            if let t = model.toast { toast(t) }
        }
        .opacity(model.player == nil ? 1 : 0)
        .overlay {
            if let req = model.player {
                PhonePlayer(request: req, hardwareDecoding: model.prefs.hardwareDecoding)
                    .id(req.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.player?.id)
        .animation(.easeOut(duration: 0.18), value: pushed)
        .tint(model.accent)
        .preferredColorScheme(.dark)
        // the pages' type follows the reader's text size (Theme's `scaledFont`) up to the second
        // accessibility size; past it a title's art could no longer hold its own title
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task { await model.loadHome() }
        // ONE owner for the screen lock. Each player used to set it on appear and clear it on
        // disappear, and the old player fading out after the next episode's had appeared
        // switched auto-lock back on in the middle of it. It follows `playingId` — a picture
        // that is actually moving — so a paused or failed player lets the phone sleep.
        .onChange(of: model.playingId != nil) { moving in
            UIApplication.shared.isIdleTimerDisabled = moving
        }
        // the sound is taken when a player opens; the player gives it back once its engine is
        // really gone (PhonePlayer.finish), not after a guess at how long that takes
        .onChange(of: model.player != nil) { open in
            if open { Audio.begin() }
        }
    }

    @ViewBuilder
    private func tabRoot(_ t: Tab) -> some View {
        switch t {
        case .home: HomeView()
        case .search: SearchView()
        case .library: LibraryView()
        case .addons: AddonsView()
        case .settings: SettingsView()
        }
    }

    @ViewBuilder
    private func page(_ r: Route) -> some View {
        switch r {
        case .detail(let item, let addonUrl): DetailView(item: item, addonUrl: addonUrl)
        case .streams(let t): StreamsView(target: t)
        case .catalog(let t): CatalogView(target: t)
        }
    }

    /// The status bar's height: the safe area above the pages (0 in landscape, where a phone
    /// hides it). Read from the window when the layout reports none, as it can on a first pass.
    @MainActor static func statusBar(_ geo: GeometryProxy) -> CGFloat {
        if geo.safeAreaInsets.top > 0 { return geo.safeAreaInsets.top }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return window?.safeAreaInsets.top ?? 0
    }

    private func toast(_ t: Toast) -> some View {
        VStack {
            Spacer()
            Text(t.text)
                .scaledFont(size: 13, weight: .medium).foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 10).frame(minHeight: 38)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(t.isError ? Theme.danger.opacity(0.7) : .white.opacity(0.14)))
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 20)
                .padding(.bottom, pushed ? 28 : 96)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .allowsHitTesting(false)
    }
}

/// The floating tab bar. Nebula's own material rather than a system `TabView`, because the app
/// is dark end to end and a system bar would sit on it as a grey slab.
struct TabPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                let on = model.tab == t
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    model.select(t)
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: on ? filled(t) : t.icon)
                            .font(.system(size: 17, weight: .medium))
                        Text(short(t))
                            .font(.system(size: 9.5, weight: on ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(on ? model.accent : Theme.label3)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func filled(_ t: Tab) -> String { t == .search ? t.icon : t.icon + ".fill" }

    /// The sidebar can afford "My List"; five labels across a phone cannot.
    private func short(_ t: Tab) -> String { t == .library ? "List" : t.title }
}

/// A page's own frame and the strip above it, where the status bar sits: the art of a page that
/// runs up under the status bar is drawn there, and nothing spills out sideways or below.
struct UnderStatusBar: Shape {
    var top: CGFloat
    func path(in r: CGRect) -> Path {
        Path(CGRect(x: r.minX, y: r.minY - top, width: r.width, height: r.height + top))
    }
}
