import SwiftUI
import NebulaCore

/// The colours a profile can wear (the same eight as the account's colour everywhere else).
private let whoColours = ["#636366", "#E50914", "#0A84FF", "#30D158", "#BF5AF2", "#FF9F0A", "#FF375F", "#F2F2F7"]

/// Who's watching? (10-16: the layout of the reference the Founder sent — the mark and the question at the top, two
/// big round monograms with their names under them, "Manage Profiles" below; managing puts a pencil on each, adds an
/// "Add Profile" circle while there is room for one, and the button reads Done.) At launch with two profiles
/// (AppModel.askingWho), and from Settings › Who's watching (AppModel.whoOpen), over everything.
struct WhoPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.nebulaAccent) private var accent
    @State private var managing = false
    @State private var editing: String? = nil

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let id = editing, let v = model.viewerList.first(where: { $0.id == id }) {
                WhoEditor(v: v, onDone: { editing = nil })
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text("◆").font(.system(size: 22)).foregroundStyle(accent)
                            Text("Nebula").scaledFont(size: 26, weight: .bold).foregroundStyle(Theme.ink)
                        }
                        Text("Who's watching?").scaledFont(size: 32, weight: .bold).foregroundStyle(Theme.ink).padding(.top, 22)
                        // two to a row, the Add circle wrapping under them while managing (as the reference)
                        LazyVGrid(columns: [GridItem(.fixed(160), spacing: 24), GridItem(.fixed(160))], spacing: 36) {
                            ForEach(tileIds, id: \.self) { id in tile(id) }
                        }
                        .padding(.top, 60)
                        Button(action: { managing.toggle() }) {
                            Text(managing ? "Done" : "Manage Profiles")
                                .scaledFont(size: 18, weight: .semibold)
                                .foregroundStyle(managing ? Theme.ink : Theme.label2)
                                .padding(.horizontal, 34).padding(.vertical, 14)
                                .background(Capsule().fill(managing ? Theme.surface2 : Color.clear))
                                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72).padding(.bottom, 40)
                }
            }
        }
        #if os(macOS)
        // Esc steps out: the editor, then managing, then the picker (keeping the profile this device is on)
        .onExitCommand {
            if editing != nil { editing = nil } else if managing { managing = false } else { model.closeWho() }
        }
        #endif
    }

    private var tileIds: [String] {
        model.viewerList.map { $0.id } + (managing && model.viewerList.count < 2 ? ["+"] : [])
    }

    /// One profile's circle and name (or "+" for the Add Profile circle).
    @ViewBuilder private func tile(_ id: String) -> some View {
        let v = model.viewerList.first { $0.id == id }
        Button(action: {
            if let v = v {
                if managing { editing = v.id } else { model.switchViewer(v.id) }
            } else {
                model.addViewerQuietly(); editing = "b"
            }
        }) {
            VStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        // the profile this device is on wears a quiet grey ring
                        Circle().stroke(v?.id == model.viewerId ? Color.white.opacity(0.2) : Color.clear, lineWidth: 5)
                            .frame(width: 152, height: 152)
                        if let v = v {
                            WhoMonogram(hex: model.viewerAvatar(v), name: model.viewerName(v), size: 140)
                        } else {
                            Circle().fill(Theme.surface)
                                .overlay(Circle().stroke(Theme.line, lineWidth: 1.5))
                                .frame(width: 140, height: 140)
                                .overlay(Image(systemName: "plus").font(.system(size: 42, weight: .light)).foregroundStyle(Theme.label2))
                        }
                    }
                    if managing && v != nil {
                        Circle().fill(Color(hex: "#F2F2F7")).frame(width: 42, height: 42)
                            .overlay(Image(systemName: "pencil").font(.system(size: 18, weight: .semibold)).foregroundStyle(.black))
                            .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                            .offset(x: -2, y: -6)
                    }
                }
                Text(v.map { model.viewerName($0) } ?? "Add Profile")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(v == nil ? Theme.label2 : Theme.ink)
                    .lineLimit(1)
            }
            .frame(width: 160)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The big monogram: the profile's colour as a deep tint, a ring of it, and the letter in it.
struct WhoMonogram: View {
    let hex: String
    let name: String
    let size: CGFloat

    var body: some View {
        let c = Color(hex: hex)
        Circle().fill(Theme.bg)
            .overlay(Circle().fill(c.opacity(0.2)))
            .overlay(Circle().stroke(c.opacity(0.6), lineWidth: 2))
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(c)
            )
    }
}

/// A pencil pressed: the profile's name and colour; the second can be removed (its history and add-ons are kept).
private struct WhoEditor: View {
    @EnvironmentObject var model: AppModel
    let v: Viewer
    let onDone: () -> Void
    @State private var name = ""
    @State private var av = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Edit profile").scaledFont(size: 28, weight: .bold).foregroundStyle(Theme.ink)
                WhoMonogram(hex: av, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? model.viewerName(v) : name, size: 132)
                    .padding(.top, 32)
                TextField(model.viewerName(Viewer(id: v.id, name: "", av: "")), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .padding(.top, 28)
                    .onSubmit { save() }
                HStack(spacing: 10) {
                    ForEach(whoColours, id: \.self) { hex in
                        Button(action: { av = hex }) {
                            Circle().fill(Color(hex: hex)).frame(width: 28, height: 28).padding(3)
                                .overlay(Circle().stroke(hex.caseInsensitiveCompare(av) == .orderedSame ? Color.white : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 22)
                Button(action: { save() }) {
                    Text("Save").scaledFont(size: 18, weight: .semibold).foregroundStyle(.black)
                        .padding(.horizontal, 40).padding(.vertical, 14)
                        .background(Capsule().fill(Color(hex: "#F2F2F7")))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 36)
                if v.id == "b" {
                    Button(action: { model.removeSecondViewer(); onDone() }) {
                        Text("Remove profile").scaledFont(size: 16, weight: .medium).foregroundStyle(Theme.danger)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                }
                Text("Each profile keeps its own Continue Watching, resume points, My List and add-ons. Settings are shared.")
                    .scaledFont(size: 13).foregroundStyle(Theme.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.top, 72).padding(.bottom, 40)
        }
        .onAppear { name = v.name; av = model.viewerAvatar(v) }
    }

    private func save() { model.editViewer(v.id, name: name, av: av); onDone() }
}

/// Settings › Who's watching: one row that opens the picker (switch, add, edit — all there now).
struct WhoSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel {
            PanelRow(
                title: "Profiles",
                detail: (model.viewerList.count < 2 ? "Add a second profile for someone else in the house." : "Watching as \(model.viewerName(model.viewerNow)).")
                    + " Each profile keeps its own Continue Watching, resume points, My List and add-ons. Settings are shared."
            ) {
                Chip(text: "Who's watching") { model.whoOpen = true }
            }
        }
    }
}
