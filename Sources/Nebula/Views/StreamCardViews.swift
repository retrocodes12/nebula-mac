import SwiftUI
import NebulaCore

/// A stream drawn as a card in one of the designs (Settings › Streams › Stream cards) — the shared player's release
/// card. Stacked: the title · source · codec with the size and seeds at the right, a marks row (the quality chip,
/// picture and sound marks drawn white, language chips), the pills (the add-on, its own label, the service) beside a
/// white play disc, then the file's name in mono. One line: the quality in a fixed slot, the title with marks and
/// pills under it, the size, the disc. Classic is `StreamRow`.
struct StreamCard: View, Equatable {
    let stream: StreamItem
    let text: StreamRowText
    let spec: StreamCards.Spec
    let addonName: String
    var busy = false
    let action: () -> Void
    @State private var hover = false

    static func == (a: StreamCard, b: StreamCard) -> Bool {
        a.stream == b.stream && a.text == b.text && a.spec == b.spec && a.addonName == b.addonName && a.busy == b.busy
    }

    var body: some View {
        Button(action: action) {
            StreamCardBody(card: text.card, spec: spec, addonName: addonName, hover: hover, busy: busy)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Play") { action() }
            Button("Copy the stream’s address") { Platform.copy(stream.url) }
        }
    }
}

/// What a card looks like, with no button around it — the list's rows and the Settings previews draw this.
struct StreamCardBody: View {
    let card: ReleaseCard
    let spec: StreamCards.Spec
    let addonName: String
    var hover = false
    var busy = false
    @Environment(\.nebulaAccent) private var accent
    /// The card's type follows the reader's text size on a phone, like the rest of the app.
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 100

    private var row: Bool { spec.layout == .row }
    private var dense: Bool { spec.dense }
    private func pt(_ v: CGFloat) -> CGFloat { v * k / 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row { rowTop } else { stackTop }
            foot
        }
        .padding(.horizontal, dense ? 16 : 20)
        .padding(.top, dense ? 12 : row ? 14 : 18)
        .padding(.bottom, dense ? 12 : row ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: dense ? 14 : 18).fill(hover ? Theme.surface2 : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: dense ? 14 : 18).strokeBorder(hover ? Color.white.opacity(0.5) : Theme.line))
    }

    // MARK: the two layouts

    private var stackTop: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                head.lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                specColumn
            }
            if hasMarks {
                FactsFlow(lineSpacing: 0) { marksItems }
                    .padding(.top, dense ? 7 : 10)
            }
            if !pills.isEmpty || spec.play || busy {
                HStack(alignment: .center, spacing: 12) {
                    FactsFlow(lineSpacing: 0) { pillItems(small: dense) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    disc
                }
                .padding(.top, dense ? 6 : 10)
            }
        }
    }

    private var rowTop: some View {
        HStack(alignment: .center, spacing: 0) {
            if spec.res {
                Group {
                    if let r = card.res { resChip(r) } else { Color.clear.frame(width: 1, height: 1) }
                }
                .frame(minWidth: 56)
                .padding(.trailing, 14)
            }
            VStack(alignment: .leading, spacing: 6) {
                head.lineLimit(2)
                if hasMarks || !pills.isEmpty {
                    FactsFlow(lineSpacing: 0) {
                        if spec.marks { ForEach(card.marks, id: \.self) { WhiteBadge(file: $0, height: dense ? 15 : 17).padding(.trailing, 10) } }
                        if spec.langs { ForEach(card.langs, id: \.self) { langChip($0) } }
                        pillItems(small: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            specColumn.padding(.leading, 16)
            if spec.play || busy { disc.padding(.leading, 16) }
        }
    }

    // MARK: parts

    private var titleSize: CGFloat { pt(dense ? 15.5 : 17) }

    /// "The Dark Knight 2008 · BDRemux · HEVC": the title in bold, the tags muted.
    private var head: Text {
        var t = Text(card.title).font(.system(size: titleSize, weight: .bold)).foregroundColor(Theme.ink)
        if spec.tags && !card.tags.isEmpty {
            t = t + Text(" · " + card.tags.joined(separator: " · ")).font(.system(size: titleSize, weight: .medium)).foregroundColor(Theme.label2)
        }
        return t
    }

    private var seedsLine: String {
        [spec.seeds ? card.seeds.map { "↑ \($0) seeds" } : nil, spec.size ? card.bitrate : nil].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var specColumn: some View {
        let size = spec.size ? card.size : nil
        let line2 = seedsLine
        if size != nil || !line2.isEmpty || card.note != nil {
            VStack(alignment: .trailing, spacing: 3) {
                if let s = size { Text(s).font(.system(size: pt(dense ? 14 : 15), weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink) }
                if !line2.isEmpty { Text(line2).font(.system(size: pt(12), design: .monospaced)).foregroundStyle(Theme.label2) }
                if let n = card.note { Text(n).font(.system(size: pt(11), design: .monospaced)).foregroundStyle(Theme.label3) }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.top, row ? 0 : 2)
        }
    }

    private var hasMarks: Bool {
        (spec.res && card.res != nil && !row) || (spec.marks && !card.marks.isEmpty) || (spec.langs && !card.langs.isEmpty)
    }

    @ViewBuilder private var marksItems: some View {
        if spec.res, let r = card.res { resChip(r).padding(.trailing, 12).padding(.vertical, 3) }
        if spec.marks { ForEach(card.marks, id: \.self) { WhiteBadge(file: $0, height: dense ? 17 : 20).padding(.trailing, 12).padding(.vertical, 3) } }
        if spec.langs { ForEach(card.langs, id: \.self) { langChip($0) } }
    }

    /// The quality as a white chip: "4K", "1080p".
    private func resChip(_ r: String) -> some View {
        Text(r)
            .font(.system(size: pt(13), weight: .bold))
            .foregroundStyle(Color.black)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
    }

    private func langChip(_ code: String) -> some View {
        Text(code)
            .font(.system(size: pt(11.5), weight: .semibold, design: .monospaced)).tracking(0.5)
            .foregroundStyle(Theme.label2)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface2))
            .padding(.trailing, 6).padding(.vertical, 3)
    }

    /// Who has it: the add-on, its own label for the row, then the service inside it.
    private var pills: [String] {
        var out: [String] = []
        if spec.addon && !addonName.isEmpty { out.append(addonName) }
        if spec.service && !card.label.isEmpty { out.append(card.label) }
        if spec.service, let p = card.provider { out.append(p) }
        return out
    }

    @ViewBuilder private func pillItems(small: Bool) -> some View {
        ForEach(Array(pills.enumerated()), id: \.offset) { _, p in
            Text(p)
                .font(.system(size: pt(small ? 12.5 : 13.5), weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, small ? 11 : 14).padding(.vertical, small ? 5 : 8)
                .background(Capsule().fill(Theme.surface2))
                .padding(.trailing, 8).padding(.vertical, 3)
        }
    }

    /// The white play disc; the accent under the pointer; a spinner while the tap waits.
    @ViewBuilder private var disc: some View {
        let side: CGFloat = dense ? 38 : 46
        if busy {
            ProgressView().controlSize(.small).frame(width: side, height: side)
        } else if spec.play {
            Image(systemName: "play.fill")
                .font(.system(size: dense ? 14 : 17, weight: .bold))
                .foregroundStyle(hover ? accent.readableInk : Color.black)
                .offset(x: 1.5)
                .frame(width: side, height: side)
                .background(Circle().fill(hover ? accent : Color.white))
        }
    }

    /// Under a hairline: the file's own name in mono, or the description when the row names no file.
    @ViewBuilder private var foot: some View {
        if spec.file && (!card.file.isEmpty || !card.desc.isEmpty) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Theme.line).frame(height: 1)
                Group {
                    if !card.file.isEmpty {
                        Text(card.file).font(.system(size: pt(12.5), design: .monospaced)).foregroundStyle(Theme.label3)
                    } else {
                        Text(card.desc).font(.system(size: pt(13))).foregroundStyle(Theme.label2)
                    }
                }
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, row ? 10 : 12)
            }
            .padding(.top, row ? 12 : 14)
        }
    }
}

/// A picture or sound mark drawn white, as the marks on a disc box are: the pack's art comes in brand colours, so it
/// is made grey and then doubled in brightness (the web's grayscale + brightness 1.9).
struct WhiteBadge: View {
    let file: String
    var height: CGFloat = 20

    var body: some View {
        if let img = BadgeImage.load(file) {
            let base = Image(platform: img).resizable().aspectRatio(contentMode: .fit).grayscale(1)
            base.overlay(base.blendMode(.plusLighter))
                .compositingGroup()
                .frame(height: height)
                .frame(maxWidth: height * 4.5)
        }
    }
}

/// A design drawn small over the sample row (`StreamCards.sample`), in a well of one height — the Settings gallery's
/// tiles and nothing else. The card is laid out at a real row's width and scaled down, so it keeps its proportions.
struct StreamCardPreview: View {
    let spec: StreamCards.Spec?
    var height: CGFloat = 150
    var layoutWidth: CGFloat = 520

    static let sample = StreamRowText(StreamCards.sample, addonName: StreamCards.sampleAddon)

    var body: some View {
        GeometryReader { g in
            let s = min(1, max(0.3, (g.size.width - 16) / layoutWidth))
            card.frame(width: layoutWidth)
                .scaleEffect(s)
                .frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var card: some View {
        if let sp = spec {
            StreamCardBody(card: StreamCardPreview.sample.card, spec: sp, addonName: StreamCards.sampleAddon)
        } else {
            ClassicRowBody(text: StreamCardPreview.sample)
        }
    }
}
