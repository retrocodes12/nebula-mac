import SwiftUI
import AppKit
import NebulaCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    /// Esc on a pushed page goes Back (B5).
    @State private var escMonitor: Any?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Sidebar()
                ZStack {
                    // every tab stays alive under the others so a row keeps its place — but only
                    // the one on screen answers keys, the keyboard and VoiceOver: a hidden page's
                    // buttons kept their shortcuts (⌘[ popped pages nobody could see)
                    ForEach(Tab.allCases) { t in
                        let shown = model.tab == t && model.path.isEmpty
                        tabRoot(t)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                            .disabled(!shown)
                            .accessibilityHidden(!shown)
                    }
                    ForEach(Array(model.path.enumerated()), id: \.offset) { i, route in
                        // keyed by place in the stack (the same page can sit in it twice, apart),
                        // and by the page itself, so a new page in an old place starts fresh
                        let shown = i == model.path.count - 1
                        page(route)
                            .id(route)
                            .background(Theme.bg)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                            .disabled(!shown)
                            .accessibilityHidden(!shown)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
            .opacity(model.player == nil ? 1 : 0)
            // under a film the whole browse layer is asleep, its shortcuts with it
            .disabled(model.player != nil)
            .accessibilityHidden(model.player != nil)

            if let req = model.player {
                PlayerScreen(request: req, hardwareDecoding: model.prefs.hardwareDecoding)
                    .id(req.id)
                    .transition(.opacity)
            }

            if let t = model.toast {
                VStack {
                    Spacer()
                    Text(t.text)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(minHeight: 38)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(t.isError ? Theme.danger.opacity(0.7) : .white.opacity(0.14)))
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, 34)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.player?.id)
        .background(Theme.bg)
        .ignoresSafeArea()
        .tint(model.accent)
        .environment(\.nebulaAccent, model.accent)
        .preferredColorScheme(.dark)
        .task { await model.loadHome() }
        .onAppear(perform: watchEscape)
        .onDisappear {
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
        // a page pushed over Search must not leave the hidden field holding the keyboard: Esc
        // (and every other key) went to a field nobody could see
        .onChange(of: model.path.count) { n in
            if n > 0, let w = NSApp.keyWindow, w.firstResponder is NSText { w.makeFirstResponder(nil) }
        }
    }

    /// Esc goes Back from a pushed page, as the Back button does — not over a film (the player
    /// has its own Esc) and not while a field is being typed in (Esc is the field's there).
    private func watchEscape() {
        guard escMonitor == nil else { return }
        let m = model
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak m] ev in
            guard ev.keyCode == 53, let m = m, m.player == nil, !m.path.isEmpty,
                  ev.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return ev }
            m.path.removeLast()
            return nil
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
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                NebulaMark(size: 22)
                Text("Nebula").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14).padding(.top, 46).padding(.bottom, 22)

            ForEach(Tab.allCases) { t in
                let on = model.tab == t
                Button(action: { model.select(t) }) {
                    HStack(spacing: 11) {
                        Image(systemName: on ? t.icon + (t == .search ? "" : ".fill") : t.icon)
                            .font(.system(size: 14, weight: .medium)).frame(width: 20)
                            .foregroundStyle(on ? model.accent : Theme.label2)
                        Text(t.title).font(.system(size: 13.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.ink : Theme.label2)
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.surface2 : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let tag = model.updateTag {
                Button(action: { if let u = URL(string: AppInfo.repo + "/releases/latest") { NSWorkspace.shared.open(u) } }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(model.accent)
                        Text("Update to \(tag)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.bottom, 6)
            }
            Button(action: { model.select(.settings) }) {
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: model.profile?.avatar ?? "#636366")).frame(width: 28, height: 28)
                        .overlay(Text(String((model.profile?.name ?? "?").prefix(1)).uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.profile?.name ?? "Sign in").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        // two lines when it needs them: one line cut it to "Sync with your TV an…"
                        Text(model.profile.map { "@" + $0.handle } ?? "Sync with your TV and phone").font(.system(size: 10.5)).foregroundStyle(Theme.label3)
                            .lineLimit(model.profile == nil ? 2 : 1).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 214)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

/// The mark the other Nebula apps wear: the accent disc with a play triangle, drawn not shipped.
/// It takes the accent from the environment, not the model, so the model's every change does
/// not redraw it.
struct NebulaMark: View {
    @Environment(\.nebulaAccent) var accent
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            Circle().fill(accent)
            Image(systemName: "play.fill").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(accent.readableInk).offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
    }
}
