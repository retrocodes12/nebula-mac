import SwiftUI
import NebulaCore

/// Settings › Streams › Stream cards: each design a tile wearing a small live copy of a real row, the current one
/// outlined in the accent; Custom opens its layout, spacing and parts with a live card under them. Device-local.
struct StreamCardSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.nebulaAccent) private var accent
    @State private var style = "release"
    @State private var custom = StreamCards.Spec()

    /// The screenshot rig scrolls Settings to the Custom controls by this id.
    static let customId = "streams-custom"

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stream cards").scaledFont(size: 14, weight: .medium).foregroundStyle(Theme.ink)
                    Text("How each stream in the list looks · Custom is yours to build")
                        .scaledFont(size: 12).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(StreamCards.designs, id: \.id) { d in tile(d) }
                }
            }
            .padding(16)
            if style == "custom" {
                Hairline()
                PanelRow(title: "Layout", detail: "Stacked like Release, or one line per stream") {
                    HStack(spacing: 6) {
                        Chip(text: "Stacked", on: custom.layout == .stack) { edit { $0.layout = .stack } }
                        Chip(text: "One line", on: custom.layout == .row) { edit { $0.layout = .row } }
                    }
                }
                .id(StreamCardSettings.customId)
                Hairline()
                PanelRow(title: "Spacing", detail: "Roomy, or less air and a smaller play button") {
                    HStack(spacing: 6) {
                        Chip(text: "Roomy", on: !custom.dense) { edit { $0.dense = false } }
                        Chip(text: "Compact", on: custom.dense) { edit { $0.dense = true } }
                    }
                }
                Hairline()
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show").scaledFont(size: 14, weight: .medium).foregroundStyle(Theme.ink)
                        Text("Each part on or off").scaledFont(size: 12).foregroundStyle(Theme.label2)
                    }
                    FactsFlow(lineSpacing: 0) {
                        ForEach(StreamCards.parts, id: \.id) { p in
                            Chip(text: p.name, on: custom[p.id]) { edit { $0[p.id].toggle() } }
                                .accessibilityAddTraits(custom[p.id] ? .isSelected : [])
                                .padding(.trailing, 8).padding(.vertical, 4)
                        }
                    }
                    StreamCardBody(card: StreamCardPreview.sample.card, spec: custom, addonName: StreamCards.sampleAddon)
                        .frame(maxWidth: 640, alignment: .leading)
                        .allowsHitTesting(false)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .onAppear {
            style = model.prefs.streamStyle
            custom = StreamCards.custom(model.prefs.streamCustom)
        }
    }

    private func tile(_ d: StreamCards.Design) -> some View {
        let on = d.id == style
        return Button { choose(d.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                StreamCardPreview(spec: d.id == "custom" ? custom : d.spec)
                Text(d.name).scaledFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink).padding(.top, 10)
                Text(d.sub).scaledFont(size: 12).foregroundStyle(Theme.label2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? accent : Theme.line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.name)
        .accessibilityHint(d.sub)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func choose(_ id: String) {
        // the first Custom starts from the design that was showing, so it is a tweak, not a blank page
        if id == "custom" && model.prefs.streamCustom == nil {
            let first = StreamCards.firstCustom(from: style, custom: nil)
            model.prefs.streamCustom = first
            custom = StreamCards.custom(first)
        }
        model.prefs.streamStyle = id
        style = id
    }

    private func edit(_ change: (inout StreamCards.Spec) -> Void) {
        change(&custom)
        model.prefs.streamCustom = custom.object
    }
}
