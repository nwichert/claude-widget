import Combine
import Foundation

struct Insights: Equatable, Decodable {
    struct Totals: Equatable, Decodable { var sessions: Int; var prompts: Int; var outputTokens: Int }
    struct Project: Equatable, Decodable, Identifiable {
        var name: String; var sessions: Int; var prompts: Int; var outputTokens: Int
        var id: String { name }
    }
    struct Activity: Equatable, Decodable, Identifiable {
        var label: String; var share: Int
        var id: String { label }
    }
    struct SkillIdea: Equatable, Decodable, Identifiable {
        var name: String
        /// Roughly how many times the pattern showed up in the window.
        var seen: Int?
        var why: String
        /// A ready-made request that asks Claude to build the skill.
        var prompt: String
        var id: String { name }
    }

    var updatedAt: Date?
    var windowDays: Int
    var totals: Totals
    var projects: [Project]
    /// A Claude session's reading of what the prompts were for; shares are estimates.
    var activities: [Activity]?
    var skillIdeas: [SkillIdea]?
}

/// Usage over the last couple of weeks, plus skills worth creating.
///
/// The counts come from `tools/usage_stats.py`, which reads local transcripts exactly. Judging
/// what the work was *for*, and which repeated requests deserve a skill, takes a model, so a
/// Claude session writes both into `~/Library/Application Support/ClaudePulse/insights.json`
/// and this class only reads the file.
final class InsightsStore: ObservableObject {
    @Published private(set) var insights: Insights?

    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudePulse/insights.json")
    private var timer: Timer?
    private var lastModified: Date?

    func start() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.load() }
    }

    private func load() {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != lastModified else { return }
        lastModified = modified
        guard let data = try? Data(contentsOf: file) else { insights = nil; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Insights.self, from: data) { insights = decoded }
    }
}
