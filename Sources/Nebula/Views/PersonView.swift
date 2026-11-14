import SwiftUI
import NebulaCore

/// Who a person page is for: a name pressed on a title page, the title it was pressed on (the cloud finds the person
/// through it), and the add-on that title came from (the cards open from it first, like the Universe row's).
struct PersonTarget: Hashable {
    var name: String
    var tt: String?
    var addonUrl: String
}

/// A cast member's, director's or writer's films and series (People.swift): the name, the filters that would change
/// something, a grid of ordinary cards. A card opens that title on top, so Back comes back here.
struct PersonView: View {
    @EnvironmentObject var model: AppModel
    let target: PersonTarget
    @State private var answer: People.Answer?
    @State private var kind = "all"
    @State private var tries = 0

    private var person: People.Person? { if case .found(let p)? = answer { return p }; return nil }

    var body: some View {
        let items = person?.items ?? []
        let kinds = People.kinds(for: items)
        let on = kinds.contains { $0.id == kind } ? kind : "all"
        let shown = items.filter { People.matches($0, on) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(person == nil ? " " : "\(shown.count) " + (shown.count == 1 ? "TITLE" : "TITLES"))
                    Text(target.name).scaledFont(size: 30, weight: .bold).foregroundStyle(Theme.ink)
                }
                .padding(.top, Theme.pushedTitleTop)
                switch answer {
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 60)
                case .none?:
                    EmptyState(icon: "person.crop.circle.badge.questionmark", title: "No films or series found",
                               detail: "Nothing is listed for \(target.name).")
                case .failed?:
                    EmptyState(icon: "wifi.slash", title: "Could not load this", detail: "The films and series of \(target.name) did not arrive. Check the connection, or try again in a moment.",
                               actionTitle: "Try again", action: { answer = nil; tries += 1 })
                case .found?:
                    if !kinds.isEmpty {
                        EdgeScroller {
                            ForEach(kinds, id: \.id) { k in Chip(text: k.label, on: on == k.id) { kind = k.id } }
                        }
                    }
                    PosterGrid(items: shown.map(\.meta), addonUrl: { _ in target.addonUrl })
                }
            }
            .padding(.horizontal, Theme.pad).padding(.bottom, 50)
        }
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 22).padding(.top, Theme.backTop) }
        .task(id: tries) {
            if answer == nil, let c = People.cached(target.name, target.tt) { answer = c; return }
            let a = await People.load(target.name, target.tt)
            if !Task.isCancelled { answer = a }
        }
    }
}
