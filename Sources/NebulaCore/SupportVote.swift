import Foundation

/// "Vote on what's next" — the supporters' say in what gets built (the cloud's support-vote.js). One round at a
/// time, two to six options, one ballot per supporter that can be changed while the round is open. The counts come
/// only after one's own ballot (nobody votes with the crowd) and for the last closed round. Casting needs the Plus
/// level (Supporter Plus, Founder, the monthly plan); anyone may look. The web's voteHtml and Android's Vote.kt.
///
///   GET  /v1/support/vote            → {round, mine, can, last}   signed when there is a profile
///   POST /v1/support/vote {option}   → the same, after the ballot
public struct SupportVote: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var id: String
        public var title: String
        public var note: String
        /// nil until the counts are shown (one's own ballot is in, or the round is over).
        public var votes: Int?

        public init(id: String, title: String, note: String, votes: Int?) {
            self.id = id; self.title = title; self.note = note; self.votes = votes
        }
    }

    public struct Round: Equatable, Sendable {
        public var id: String
        public var title: String
        /// When it closes, ms.
        public var closes: Int64
        public var options: [Option]
        /// How many have voted — with the counts only.
        public var voters: Int?

        public init(id: String, title: String, closes: Int64, options: [Option], voters: Int?) {
            self.id = id; self.title = title; self.closes = closes; self.options = options; self.voters = voters
        }
    }

    /// The last round that closed.
    public struct Past: Equatable, Sendable {
        public var id: String
        public var title: String
        public var closed: Int64
        /// The winning option's title; nil when nobody voted.
        public var winner: String?
        public var voters: Int
        public var options: [Option]
    }

    public var round: Round?
    /// This profile's ballot in the open round — always one of its options, else nil.
    public var mine: String?
    /// This profile may vote (the server's word, from its tier).
    public var can: Bool
    public var last: Past?

    public init(round: Round?, mine: String?, can: Bool, last: Past?) {
        self.round = round; self.mine = mine; self.can = can; self.last = last
    }

    public static let empty = SupportVote(round: nil, mine: nil, can: false, last: nil)

    public var voted: Bool { mine != nil }

    /// The answer of either call. Options with no id or title are dropped (a round left with none is no round);
    /// text is capped as the server caps it.
    public static func parse(_ o: JSONObject) -> SupportVote {
        func clip(_ j: JSONObject, _ k: String, _ n: Int) -> String {
            String((j[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(n))
        }
        // no `is Bool` test: on Apple's Foundation a JSON 1 passes for true, and a single vote would vanish
        func count(_ j: JSONObject, _ k: String) -> Int? { j.optInt(k).map { max(0, $0) } }
        func options(_ j: JSONObject) -> [Option] {
            j.objs("options").compactMap { x in
                let id = clip(x, "id", 40), title = clip(x, "title", 80)
                return id.isEmpty || title.isEmpty ? nil : Option(id: id, title: title, note: clip(x, "note", 200), votes: count(x, "votes"))
            }
        }
        var round: Round?
        if let j = o.obj("round") {
            let opts = options(j)
            if !opts.isEmpty {
                let title = clip(j, "title", 80)
                round = Round(id: clip(j, "id", 40), title: title.isEmpty ? "What should Nebula build next?" : title,
                              closes: j.int64("closes"), options: opts, voters: count(j, "voters"))
            }
        }
        let m = clip(o, "mine", 40)
        let mine = round?.options.contains { $0.id == m } == true ? m : nil
        var last: Past?
        if let j = o.obj("last") {
            let w = j.obj("winner").map { clip($0, "title", 80) } ?? ""
            last = Past(id: clip(j, "id", 40), title: clip(j, "title", 80), closed: j.int64("closed"),
                        winner: w.isEmpty ? nil : w, voters: max(0, j.int("voters")), options: options(j))
        }
        return SupportVote(round: round, mine: mine, can: o.bool("can"), last: last)
    }

    /// Each option's share of the ballots in whole percent, largest remainder first, so the column adds up to 100.
    public static func shares(_ votes: [Int]) -> [Int] {
        let total = votes.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return votes.map { _ in 0 } }
        let exact = votes.map { Double(max(0, $0)) * 100 / Double(total) }
        var out = exact.map { Int($0) }
        var left = 100 - out.reduce(0, +)
        // the biggest fractions take the points left over; a tie goes to the option listed first
        let order = exact.indices.sorted { a, b in
            let fa = exact[a] - Double(out[a]), fb = exact[b] - Double(out[b])
            return fa != fb ? fa > fb : a < b
        }
        for i in order where left > 0 { out[i] += 1; left -= 1 }
        return out
    }

    /// A failed ballot, in a sentence (the server's error strings, support-vote.js).
    public static func errorText(_ e: Error) -> String {
        guard let f = e as? HTTPFailure else { return "Could not reach the server." }
        switch f.error {
        case "vote needs plus": return "The vote is for Supporter Plus, Founders and Monthly supporters."
        case "no vote open": return "That vote has just closed."
        case "unknown option": return "That choice is no longer on the ballot."
        case "no profile": return "Sign in first — your vote lives on your profile."
        default: return f.code == 401 ? "Sign in first — your vote lives on your profile." : Cloud.errorText(e)
        }
    }
}
