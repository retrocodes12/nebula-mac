import SwiftUI
import NebulaCore

struct AddonsView: View {
    @EnvironmentObject var model: AppModel
    @State private var address = ""
    @State private var busy = false
    @State private var error: String?
    @State private var removing: Addon?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add-ons").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Add-ons bring the catalogs, the details, the streams and the subtitles. Nebula asks them in the order below.")
                        .font(.system(size: 13)).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: Theme.cap(560), alignment: .leading)
                }
                .padding(.top, 56)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("Paste an add-on’s address or install link", text: $address)
                            .entry(.address)
                            .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                            .onSubmit(install)
                        Button(action: install) { if busy { ProgressView().controlSize(.small) } else { Text("Add") } }
                            .buttonStyle(PillButtonStyle()).disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let e = error { Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.danger) }
                }
                .frame(maxWidth: Theme.cap(720))

                Panel {
                    ForEach(Array(model.addons.enumerated()), id: \.element.manifestUrl) { i, a in
                        if i > 0 { Hairline() }
                        row(a, i)
                    }
                }
                .frame(maxWidth: Theme.cap(720))
            }
            .padding(.horizontal, Theme.pad).padding(.bottom, 50)
        }
        .background(Theme.bg)
        .confirmationDialog("Remove \(removing?.name ?? "this add-on")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let r = removing { model.saveAddons(model.addons.filter { $0.manifestUrl != r.manifestUrl }); model.say("Removed \(r.name).") }
                removing = nil
            }
        } message: { Text("Its catalogs and streams go with it. With a profile, it is removed from your other devices too.") }
    }

    private func row(_ a: Addon, _ i: Int) -> some View {
        HStack(spacing: 14) {
            RemoteImage(url: a.logo, contentMode: .fit) { ZStack { Theme.surface2; Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.label3) } }
                .frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(a.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(a.enabled ? Theme.ink : Theme.label3)
                Text(URL(string: a.base)?.host ?? a.base).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.label3).lineLimit(1)
            }
            Spacer()
            HStack(spacing: Self.iconGap) {
                iconButton("chevron.up", "Move up", disabled: i == 0) { move(i, -1) }
                iconButton("chevron.down", "Move down", disabled: i == model.addons.count - 1) { move(i, 1) }
                iconButton("trash", "Remove", disabled: false) { removing = a }
            }
            Toggle("", isOn: Binding(get: { a.enabled }, set: { on in
                var next = model.addons; next[i].enabled = on; model.saveAddons(next)
            }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func iconButton(_ icon: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(disabled ? Theme.label3.opacity(0.4) : Theme.label2)
                .frame(width: 28, height: 28).contentShape(Rectangle())
                .touchArea()
        }
        .buttonStyle(.plain).disabled(disabled).help(label)
    }

    // a phone's 44-point targets already sit edge to edge
    #if os(iOS)
    private static let iconGap: CGFloat = 0
    #else
    private static let iconGap: CGFloat = 2
    #endif

    private func move(_ i: Int, _ d: Int) {
        var next = model.addons
        next.swapAt(i, i + d)
        model.saveAddons(next, reordered: true)
    }

    private func install() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            error = await model.installAddon(address)
            if error == nil { address = "" }
            busy = false
        }
    }
}
