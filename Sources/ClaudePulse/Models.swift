import Foundation

enum SessionState: Int, Comparable {
    /// Claude is stopped on a question or approval, or ended its turn by asking you something.
    case needsInput = 0
    /// Claude finished and has not been looked at since.
    case needsYou = 1
    case working = 2
    case idle = 3

    static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }
}

struct TokenTotals: Equatable {
    /// Size of the prompt on the most recent main-thread turn (how full the context is).
    var context = 0
    /// Largest prompt seen in this session; used to infer how big the model's window is.
    var peakContext = 0
    /// Summed over the whole session, sub-agents included.
    var output = 0
    var input = 0
    var cacheRead = 0
    /// Whether Claude's latest message on the main thread ends in a question mark.
    var endsWithQuestion = false
    /// The question Claude left in its end-of-turn box, while nobody has answered it.
    var openAsk: String?
}

struct SessionRow: Identifiable, Equatable {
    let id: String
    var title: String
    var project: String
    var cwd: String
    var model: String
    var state: SessionState
    var waitingFor: String?
    var lastActivity: Date
    /// `local_…` id used by Claude Desktop; nil for sessions started in a terminal.
    var desktopId: String?
    var cliSessionId: String?
    var isLive: Bool
    var tokens: TokenTotals
    /// Inferred size of the model's context window, in tokens. See `SessionStore.window(for:)`.
    var contextWindow = 200_000
    var git: GitInfo?
    var pr: PRInfo?
    /// What Claude is asking for, when known.
    var prompt: String?

    /// Either "answer me" or "I'm done": the next move is yours.
    var wantsYou: Bool { state == .needsInput || state == .needsYou }

    var contextFraction: Double {
        contextWindow > 0 ? min(1, Double(tokens.context) / Double(contextWindow)) : 0
    }

    var openURL: URL? {
        guard let desktopId,
              let q = desktopId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        // `/continue` opens any session; `/needs-input` only navigates for ones flagged as waiting.
        return URL(string: "claude://code/continue?session=\(q)")
    }
}

struct PlanUsage: Equatable {
    var fiveHour: Int
    var sevenDay: Int
    var sampledAt: Date
}

enum Format {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000: return "\(n / 1_000)k"
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3_600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3_600)h"
        default: return "\(s / 86_400)d"
        }
    }

    static func span(hours: Int) -> String {
        hours < 24 ? "\(hours) hours" : hours == 24 ? "day" : "\(hours / 24) days"
    }

    /// "claude-fable-5-2" -> "Fable 5.2"
    static func model(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let name = parts.first else { return "" }
        let version = parts.dropFirst().filter { $0.count <= 2 && Int($0) != nil }.joined(separator: ".")
        return version.isEmpty ? name.capitalized : "\(name.capitalized) \(version)"
    }
}
