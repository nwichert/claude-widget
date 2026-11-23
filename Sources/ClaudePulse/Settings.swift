import Combine
import Foundation

/// User preferences, stored in UserDefaults. The reader thread reads the same keys directly.
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Key {
        static let notify = "notifyOnFinish"   // the master switch; the key name predates the others
        static let notifySessions = "notifySessions"
        static let notifyArtifacts = "notifyArtifacts"
        static let notifyDuet = "notifyDuet"
        static let notifyChats = "notifyChats"
        static let remindMinutes = "remindMinutes"
        static let recentHours = "recentHours"
        static let showGit = "showGit"
        static let showContext = "showContext"
        static let showChats = "showChats"
        static let hiddenChats = "hiddenChats"
        static let showArtifacts = "showArtifacts"
        static let showGitHub = "showGitHub"
        static let showInsights = "showInsights"   // older single switch; now the default for the two below
        static let showCode = "showCode"
        static let showSkillIdeas = "showSkillIdeas"
        static let showUsage = "showUsage"
        static let showDuet = "showDuet"
        static let dismissedIdeas = "dismissedIdeas"
        static let duetPeekMinutes = "duetPeekMinutes"
        static let duetWatchMinutes = "duetWatchMinutes"
        static let chatsLookMinutes = "chatsLookMinutes"
        static let observeScreen = "observeScreen"
        static let observePaused = "observePaused"
        static let observeExcludedApps = "observeExcludedApps"
        static let observeRetentionDays = "observeRetentionDays"
    }

    /// Apps never recorded by the screen observer unless you remove them from the list: password
    /// managers, system settings and messages.
    static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences",
        "com.apple.MobileSMS",
    ]

    /// How often to send Claude's window to Duet for a look while a Duet task is running and Duet
    /// is not on screen; 0 never does. The first look after you leave Duet comes after a minute.
    @Published var duetPeekMinutes: Int { didSet { defaults.set(duetPeekMinutes, forKey: Key.duetPeekMinutes) } }
    /// How often to check Duet when nothing is known to be running, so tasks started elsewhere are found. 0 = never.
    @Published var duetWatchMinutes: Int { didSet { defaults.set(duetWatchMinutes, forKey: Key.duetWatchMinutes) } }
    /// How often to flip Claude's window to its chat tab to read the chat list while you are in a
    /// Code session. 0 = never (chats are then read only while that tab is on screen), -1 = Live.
    @Published var chatsLookMinutes: Int { didSet { defaults.set(chatsLookMinutes, forKey: Key.chatsLookMinutes) } }

    /// Off unless you switch it on: record the front app, window title and visible text so a
    /// Claude session can suggest skills from work done outside Claude.
    @Published var observeScreen: Bool { didSet { defaults.set(observeScreen, forKey: Key.observeScreen) } }
    /// A temporary stop from the menu. Stored so the observer's queue can read it, but every
    /// launch starts unpaused.
    @Published var observePaused = false { didSet { defaults.set(observePaused, forKey: Key.observePaused) } }
    /// Bundle ids the observer skips entirely.
    @Published var observeExcludedApps: [String] {
        didSet { defaults.set(observeExcludedApps, forKey: Key.observeExcludedApps) }
    }
    /// Days of screen activity kept on disk.
    @Published var observeRetentionDays: Int {
        didSet { defaults.set(observeRetentionDays, forKey: Key.observeRetentionDays) }
    }

    @Published var notifySessions: Bool { didSet { defaults.set(notifySessions, forKey: Key.notifySessions) } }
    @Published var notifyArtifacts: Bool { didSet { defaults.set(notifyArtifacts, forKey: Key.notifyArtifacts) } }
    @Published var notifyDuet: Bool { didSet { defaults.set(notifyDuet, forKey: Key.notifyDuet) } }
    /// A chat you asked something and left has its answer.
    @Published var notifyChats: Bool { didSet { defaults.set(notifyChats, forKey: Key.notifyChats) } }
    /// Master switch for every notification Claude Pulse sends.
    @Published var notifyOnFinish: Bool { didSet { defaults.set(notifyOnFinish, forKey: Key.notify) } }
    /// Minutes a session may wait before one follow-up notification; 0 turns reminders off.
    @Published var remindMinutes: Int { didSet { defaults.set(remindMinutes, forKey: Key.remindMinutes) } }
    /// How long a session with no running process stays listed.
    @Published var recentHours: Int { didSet { defaults.set(recentHours, forKey: Key.recentHours) } }
    @Published var showGit: Bool { didSet { defaults.set(showGit, forKey: Key.showGit) } }
    @Published var showContext: Bool { didSet { defaults.set(showContext, forKey: Key.showContext) } }

    @Published var showChats: Bool { didSet { defaults.set(showChats, forKey: Key.showChats) } }

    @Published var showDuet: Bool { didSet { defaults.set(showDuet, forKey: Key.showDuet) } }
    @Published var showCode: Bool { didSet { defaults.set(showCode, forKey: Key.showCode) } }
    @Published var showSkillIdeas: Bool { didSet { defaults.set(showSkillIdeas, forKey: Key.showSkillIdeas) } }
    /// One switch for both the 14-day usage block and the 5h / 7d plan meters in the footer.
    @Published var showUsage: Bool { didSet { defaults.set(showUsage, forKey: Key.showUsage) } }
    @Published var showInsights: Bool { didSet { defaults.set(showInsights, forKey: Key.showInsights) } }
    /// Skill ideas you have said no to, by name.
    @Published var dismissedIdeas: [String] { didSet { defaults.set(dismissedIdeas, forKey: Key.dismissedIdeas) } }
    /// The Code Caddie: a floating window with a card per agent. Off until you turn it on.
    @Published var showHuddle: Bool { didSet { defaults.set(showHuddle, forKey: "showHuddle") } }
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

    /// Whether text and spacing grow with the panel's width.
    @Published var scaleText: Bool { didSet { defaults.set(scaleText, forKey: "scaleText") } }

    /// Pull requests you have chosen to ignore: URL -> a label to show in settings.
    @Published var ignoredPullRequests: [String: String] {
        didSet { defaults.set(ignoredPullRequests, forKey: "ignoredPullRequests") }
    }

    /// Sections folded shut in the panel, by id. Reference sections start folded.
    @Published var collapsedSections: [String] {
        didSet { defaults.set(collapsedSections, forKey: "collapsedSections") }
    }

    func isCollapsed(_ id: String) -> Bool { collapsedSections.contains(id) }

    func toggleCollapsed(_ id: String) {
        if let index = collapsedSections.firstIndex(of: id) {
            collapsedSections.remove(at: index)
        } else {
            collapsedSections.append(id)
        }
        // Opening a section is looking at it; folding it starts a fresh baseline.
        collapsedSeen[id] = nil
    }

    /// For each folded section, the items it held when folded plus any you have since seen or
    /// cleared. Anything else that turns up while it is folded is new and goes under Needs You.
    @Published private(set) var collapsedSeen: [String: [String]] {
        didSet { defaults.set(collapsedSeen, forKey: "collapsedSeen") }
    }

    /// Adds `ids` to what a folded section has seen; the first call for a section sets its baseline.
    func markSeen(_ section: String, _ ids: [String]) {
        let known = collapsedSeen[section] ?? []
        let added = ids.filter { !known.contains($0) }
        guard collapsedSeen[section] == nil || !added.isEmpty else { return }
        collapsedSeen[section] = Array((known + added).suffix(500))
    }

    /// Items in a folded section that were not there when it was folded and have not been seen since.
    func newWhileCollapsed(_ section: String, _ ids: [String]) -> [String] {
        guard isCollapsed(section), let known = collapsedSeen[section] else { return [] }
        let seen = Set(known)
        return ids.filter { !seen.contains($0) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        notifyOnFinish = Self.bool(Key.notify, default: true)
        notifySessions = Self.bool(Key.notifySessions, default: true)
        notifyArtifacts = Self.bool(Key.notifyArtifacts, default: true)
        notifyDuet = Self.bool(Key.notifyDuet, default: true)
        notifyChats = Self.bool(Key.notifyChats, default: true)
        remindMinutes = Self.int(Key.remindMinutes, default: 15)
        recentHours = Self.int(Key.recentHours, default: 24)
        showGit = Self.bool(Key.showGit, default: true)
        showContext = Self.bool(Key.showContext, default: true)
        showChats = Self.bool(Key.showChats, default: true)
        showArtifacts = Self.bool(Key.showArtifacts, default: true)
        showGitHub = Self.bool(Key.showGitHub, default: true)
        showInsights = Self.bool(Key.showInsights, default: true)
        showCode = Self.bool(Key.showCode, default: true)
        // Carry over whatever the combined "usage and skill ideas" switch was set to.
        let combined = Self.bool(Key.showInsights, default: true)
        showSkillIdeas = Self.bool(Key.showSkillIdeas, default: combined)
        showUsage = Self.bool(Key.showUsage, default: combined)
        showDuet = Self.bool(Key.showDuet, default: true)
        showHuddle = Self.bool("showHuddle", default: false)
        scaleText = Self.bool("scaleText", default: true)
        ignoredPullRequests = (UserDefaults.standard.dictionary(forKey: "ignoredPullRequests") as? [String: String]) ?? [:]
        collapsedSections = UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? ["skills", "usage"]
        collapsedSeen = (UserDefaults.standard.dictionary(forKey: "collapsedSeen") as? [String: [String]]) ?? [:]
        dismissedIdeas = UserDefaults.standard.stringArray(forKey: Key.dismissedIdeas) ?? []
        hiddenChats = UserDefaults.standard.stringArray(forKey: Key.hiddenChats) ?? []
        duetPeekMinutes = Self.int(Key.duetPeekMinutes, default: 2)
        duetWatchMinutes = Self.int(Key.duetWatchMinutes, default: 5)
        chatsLookMinutes = Self.int(Key.chatsLookMinutes, default: 0)
        observeScreen = Self.bool(Key.observeScreen, default: false)
        observeExcludedApps = Self.excludedApps()
        observeRetentionDays = Self.int(Key.observeRetentionDays, default: 7)
        UserDefaults.standard.set(false, forKey: Key.observePaused)
    }

    /// The exclusion list as stored, for the observer's queue.
    static func excludedApps() -> [String] {
        UserDefaults.standard.stringArray(forKey: Key.observeExcludedApps) ?? defaultExcludedApps
    }

    func hideChat(_ title: String) {
        if !hiddenChats.contains(title) { hiddenChats.append(title) }
    }

    func unhideChat(_ title: String) {
        hiddenChats.removeAll { $0 == title }
    }

    /// The Duet look-in choices: "Live" is stored as -1.
    static let live = -1
    /// Seconds between Duet look-ins for a stored choice: nil when off, 15 seconds for Live.
    static func lookInterval(_ value: Int) -> TimeInterval? {
        value == 0 ? nil : value < 0 ? 15 : TimeInterval(value * 60)
    }

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static func int(_ key: String, default fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }
}
