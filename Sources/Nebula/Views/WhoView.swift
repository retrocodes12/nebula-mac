import SwiftUI
import NebulaCore

/// Who's watching? At launch with two profiles on the account (AppModel.askingWho), over everything.
struct WhoPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 36) {
                Text("Who's watching?").scaledFont(size: 28, weight: .semibold).foregroundStyle(Theme.ink)
                HStack(spacing: 28) {
                    ForEach(model.viewerList) { v in
                        Button(action: { model.switchViewer(v.id) }) {
                            VStack(spacing: 12) {
                                Circle().fill(Color(hex: model.viewerAvatar(v))).frame(width: 104, height: 104)
                                    .overlay(Text(String(model.viewerName(v).prefix(1)).uppercased())
                                        .font(.system(size: 42, weight: .bold)).foregroundStyle(.white))
                                Text(model.viewerName(v)).scaledFont(size: 16).foregroundStyle(Theme.label2).lineLimit(1)
                            }
                            .frame(width: 128).padding(12).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Settings › Who's watching: the profiles (pick = switch, + = add and switch to it), this one's name, removing the second.
struct WhoSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""

    var body: some View {
        Panel {
            PanelRow(title: "Profiles", detail: "Each profile keeps its own Continue Watching, resume points and My List. Add-ons and settings are shared.") {
                HStack(spacing: 6) {
                    ForEach(model.viewerList) { v in Chip(text: model.viewerName(v), on: v.id == model.viewerId) { model.switchViewer(v.id) } }
                    if model.viewerList.count < 2 { Chip(text: "+ Add a profile") { model.addViewer() } }
                }
            }
            if model.viewerList.count > 1 {
                Hairline()
                PanelRow(title: "This profile's name", detail: "Shown when Nebula asks who's watching.") {
                    TextField(model.viewerName(model.viewerNow), text: $name)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        .onSubmit { model.renameViewer(name) }
                }
                Hairline()
                PanelRow(title: "Remove the second profile", detail: "Its history is kept, and comes back if a second profile is added again.") {
                    Chip(text: "Remove") { model.removeSecondViewer() }
                }
            }
        }
        .onAppear { name = model.viewerNow.name }
        .onChange(of: model.viewerId) { _ in name = model.viewerNow.name }
    }
}
