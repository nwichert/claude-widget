import Combine
import Foundation

/// User preferences, stored in UserDefaults. The reader thread reads the same keys directly.
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Key {
        static let notify = "notifyOnFinish"
        static let remindMinutes = "remindMinutes"
        static let recentHours = "recentHours"
        static let showGit = "showGit"
        static let showContext = "showContext"
        static let showPlan = "showPlan"
        static let showChats = "showChats"
        static let hiddenChats = "hiddenChats"
        static let showArtifacts = "showArtifacts"
        static let showGitHub = "showGitHub"
        static let showInsights = "showInsights"
        static let showDuet = "showDuet"
        static let dismissedIdeas = "dismissedIdeas"
    }

    @Published var notifyOnFinish: Bool { didSet { defaults.set(notifyOnFinish, forKey: Key.notify) } }
    /// Minutes a session may wait before one follow-up notification; 0 turns reminders off.
    @Published var remindMinutes: Int { didSet { defaults.set(remindMinutes, forKey: Key.remindMinutes) } }
    /// How long a session with no running process stays listed.
    @Published var recentHours: Int { didSet { defaults.set(recentHours, forKey: Key.recentHours) } }
    @Published var showGit: Bool { didSet { defaults.set(showGit, forKey: Key.showGit) } }
    @Published var showContext: Bool { didSet { defaults.set(showContext, forKey: Key.showContext) } }
    @Published var showPlan: Bool { didSet { defaults.set(showPlan, forKey: Key.showPlan) } }

    @Published var showChats: Bool { didSet { defaults.set(showChats, forKey: Key.showChats) } }

    @Published var showDuet: Bool { didSet { defaults.set(showDuet, forKey: Key.showDuet) } }
    @Published var showInsights: Bool { didSet { defaults.set(showInsights, forKey: Key.showInsights) } }
    /// Skill ideas you have said no to, by name.
    @Published var dismissedIdeas: [String] { didSet { defaults.set(dismissedIdeas, forKey: Key.dismissedIdeas) } }
    @Published var showGitHub: Bool { didSet { defaults.set(showGitHub, forKey: Key.showGitHub) } }
    @Published var showArtifacts: Bool { didSet { defaults.set(showArtifacts, forKey: Key.showArtifacts) } }
    /// Chat titles kept out of the panel. Claude exposes no chat id locally, so the title is the key:
    /// renaming a hidden chat brings it back.
    @Published var hiddenChats: [String] { didSet { defaults.set(hiddenChats, forKey: Key.hiddenChats) } }

    /// What macOS says about this app's notifications: "authorized", "denied", "notDetermined" or "unknown".
    /// Not a preference; refreshed from the system.
    @Published var notificationAccess = "unknown" {
        didSet { defaults.set(notificationAccess, forKey: "notificationAccess") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        notifyOnFinish = Self.bool(Key.notify, default: true)
        remindMinutes = Self.int(Key.remindMinutes, default: 15)
        recentHours = Self.int(Key.recentHours, default: 24)
        showGit = Self.bool(Key.showGit, default: true)
        showContext = Self.bool(Key.showContext, default: true)
        showPlan = Self.bool(Key.showPlan, default: true)
        showChats = Self.bool(Key.showChats, default: true)
        showArtifacts = Self.bool(Key.showArtifacts, default: true)
        showGitHub = Self.bool(Key.showGitHub, default: true)
        showInsights = Self.bool(Key.showInsights, default: true)
        showDuet = Self.bool(Key.showDuet, default: true)
        dismissedIdeas = UserDefaults.standard.stringArray(forKey: Key.dismissedIdeas) ?? []
        hiddenChats = UserDefaults.standard.stringArray(forKey: Key.hiddenChats) ?? []
    }

    func hideChat(_ title: String) {
        if !hiddenChats.contains(title) { hiddenChats.append(title) }
    }

    func unhideChat(_ title: String) {
        hiddenChats.removeAll { $0 == title }
    }

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static func int(_ key: String, default fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }
}
