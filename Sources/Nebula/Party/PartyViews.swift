import SwiftUI
import NebulaCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a party plays, as the player's request describes it (the row's file name rides along so viewers can find it).
extension PlayRequest {
    var partyDesc: PartyStreamDesc {
        PartyStreamDesc(url: stream.url, title: title, subs: stream.subtitles, type: target.type, id: target.id, name: target.item.name,
                        poster: target.item.poster, addonUrl: streamAddon?.manifestUrl ?? target.addonUrl,
                        file: ReleaseKey.fileName(stream).isEmpty ? nil : ReleaseKey.fileName(stream),
                        share: PartyClient.share, keys: stream.clearKeys)
    }
}

/// Over the player: the party's card (right), its pill and incoming chat lines (bottom left), reactions.
struct PartyOverlay: View {
    @ObservedObject var party: PartyClient
    let mpv: MPVController
    let request: PlayRequest
    var bottomInset: CGFloat = 120

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                if !party.panelOpen {
                    ForEach(party.feed) { l in
                        (Text(l.name + "  ").fontWeight(.semibold) + Text(l.text))
                            .font(.system(size: 13.5)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.11).opacity(0.88)))
                    }
                }
                if !party.pill.isEmpty {
                    Button { if party.pill.hasPrefix("Paused") { party.resumeOwn() } else if party.pill.hasSuffix("Catch up") { party.catchUp() } } label: {
                        Text(party.pill).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 24).padding(.bottom, bottomInset)
            .allowsHitTesting(!party.pill.isEmpty)

            ForEach(party.reactions) { r in
                VStack(spacing: 2) {
                    Text(r.text).font(.system(size: 40))
                    if !r.name.isEmpty { Text(r.name).font(.caption2).foregroundStyle(.white.opacity(0.8)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 160)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            if party.active && party.panelOpen {
                PartyCard(party: party)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 70).padding(.trailing, 20).padding(.bottom, 20)
            }
        }
        .onAppear { party.bind(mpv, desc: request.partyDesc) }
        .onChange(of: request.id) { _ in party.bind(mpv, desc: request.partyDesc) }
        .onDisappear { party.unbind(mpv) }
    }
}

struct PartyCard: View {
    @ObservedObject var party: PartyClient
    @State private var draft = ""
    @State private var armed = ""
    @State private var armedAt = Date.distantPast

    private func twoStep(_ key: String, _ go: () -> Void) {
        if armed == key && Date().timeIntervalSince(armedAt) < 3.5 { armed = ""; go() }
        else { armed = key; armedAt = Date() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Watch together").font(.system(size: 15, weight: .bold))
                    Spacer()
                    if party.v2 { Text("\(max(1, party.members.count)) of 25 seats").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.label3) }
                    Button("Close") { party.openPanel(false) }.buttonStyle(.plain).foregroundStyle(Theme.label2)
                }
                if let a = party.ask {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Switch the party to \(a.name ?? a.title)? Everyone will start watching it with you.").font(.system(size: 13))
                        HStack {
                            Button("Switch") { party.switchParty(a); party.openPanel(false) }
                            Button("Not now") { party.ask = nil }
                        }
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(party.code ?? "").font(.system(size: 26, weight: .bold, design: .monospaced)).kerning(3)
                    Spacer()
                    Button("Copy invite") { copy("Join my Nebula watch party with code \(party.code ?? ""): https://play.rifflehq.in/?party=\(party.code ?? "")") }
                        .buttonStyle(.plain).foregroundStyle(Theme.label2)
                }
                Text("play.rifflehq.in/?party=\(party.code ?? "")").font(.system(size: 11)).foregroundStyle(Theme.label2)

                Eyebrow("Members")
                ForEach(party.members.isEmpty ? [PartyMember(id: party.id, name: "You", host: party.isHost, s: "ready")] : party.members) { m in
                    HStack(spacing: 10) {
                        Circle().fill(Color(hue: hue(m.name), saturation: 0.38, brightness: 0.55)).frame(width: 28, height: 28)
                            .overlay(Text(String(m.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(m.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                let tags = [m.id == party.id ? "You" : nil, m.host ? "Host" : nil].compactMap { $0 }.joined(separator: " · ")
                                if !tags.isEmpty { Text(tags).font(.system(size: 11)).foregroundStyle(Theme.label3) }
                            }
                            let st = m.id == party.id ? party.myStatus : PartySync.statusLabel(m)
                            if !st.isEmpty { Text(st).font(.system(size: 11.5)).foregroundStyle(["buffering", "loading", "choosing"].contains(m.s) ? Color(red: 1, green: 0.83, blue: 0.47) : Theme.label2) }
                        }
                        Spacer()
                        if party.isHost && party.v2 && m.id != party.id {
                            Button(armed == "rm:" + m.id ? "Remove \(m.name)?" : "Remove") { twoStep("rm:" + m.id) { party.kick(m.id) } }
                                .buttonStyle(.plain).foregroundStyle(armed == "rm:" + m.id ? Theme.danger : Theme.label2).font(.system(size: 12))
                        }
                    }
                }
                if party.v2 && !party.isHost && (party.hostOnly || !party.hostV2) {
                    Text("Only the host can control playback. You can still pause or rewind for yourself.").font(.system(size: 11.5)).foregroundStyle(Theme.label3)
                }
                if party.v2 {
                    Eyebrow("Chat")
                    if party.chat.isEmpty {
                        Text("No messages yet. Only people in this party can see the chat.").font(.system(size: 12)).foregroundStyle(Theme.label3)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(party.chat.suffix(40)) { c in
                                (Text((c.by == party.id ? "You" : c.name) + "  ").fontWeight(.semibold).foregroundColor(c.by == party.id ? .white : Theme.label2)
                                 + Text(c.text + (c.fail ? "  · Not sent" : "")).foregroundColor(c.fail ? Theme.danger : c.pend ? Theme.label3 : .white))
                                    .font(.system(size: 13))
                            }
                        }
                    }
                    HStack {
                        TextField("Message", text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                            .onSubmit(send)
                        Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(["👍", "😂", "❤️", "😮", "🔥"], id: \.self) { e in
                        Button(e) { party.react(e) }.buttonStyle(.plain).font(.system(size: 20))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if party.isHost && party.v2 {
                        Toggle("Only I can control playback", isOn: Binding(get: { party.hostOnly }, set: { party.setHostOnly($0) }))
                            .toggleStyle(.switch).font(.system(size: 13))
                    }
                    Button("Leave party") { party.leave() }.buttonStyle(.plain)
                    if party.isHost && party.v2 {
                        Button(armed == "end" ? "Press again to end it" : "End for everyone") { twoStep("end") { party.endForEveryone() } }
                            .buttonStyle(.plain).foregroundStyle(Theme.danger)
                    }
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.14)))
        .foregroundStyle(.white)
    }

    private func send() { party.sendChat(draft); draft = "" }
    private func hue(_ s: String) -> Double {
        var h: UInt32 = 0
        for u in s.unicodeScalars { h = h &* 31 &+ u.value }
        return Double(h % 360) / 360
    }
    private func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
        party.say?("Invite copied.")
    }
}

/// Settings › Watch party: the name friends see, a code to join, and the two choices.
struct PartySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var name = UserDefaults.standard.string(forKey: "party_name") ?? ""
    @State private var code = ""
    @State private var share = PartyClient.share
    @State private var own = PartyClient.useOwn

    var body: some View {
        Panel {
            PanelRow(title: "Party name", detail: "How you appear to friends in a watch party.") {
                TextField(PartyClient.name, text: $name)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 180, alignment: .leading).frame(minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                    .onChange(of: name) { v in UserDefaults.standard.set(String(v.prefix(40)), forKey: "party_name") }
            }
            Hairline()
            PanelRow(title: "Join a party", detail: "Enter a friend's code. To start one, press Watch party in the player.") {
                HStack {
                    TextField("CODE", text: $code)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 110).frame(minHeight: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                        .onSubmit { model.party.join(code) }
                    Button("Join") { model.party.join(code) }
                }
            }
            Hairline()
            PanelRow(title: "Share my stream", detail: "When you host, friends play your link. Off: each plays the same file from their own add-ons, and your link (with any debrid key in it) stays here.") {
                Toggle("", isOn: $share).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .onChange(of: share) { v in UserDefaults.standard.set(v, forKey: "party_share") }
            }
            Hairline()
            PanelRow(title: "Use my own add-ons", detail: "When you join, look for the host's file in your add-ons first, the host's link if none has it.") {
                Toggle("", isOn: $own).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .onChange(of: own) { v in UserDefaults.standard.set(v, forKey: "party_own") }
            }
        }
    }
}
