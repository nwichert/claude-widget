import Combine
import Foundation

struct ArtifactItem: Identifiable, Equatable, Decodable {
    var title: String
    var url: String
    /// "mine" or "shared"
    var owner: String
    var updated: String?
    var threads: Int?
    var openThreads: Int?
    /// Open comment threads that tag you and have no reply from you after the tag.
    var mentions: Int?
    var lastCommentAt: Date?
    var lastCommentBy: String?
    var mentionPreview: String?

    /// Set by the store, not the file: when this shared artifact first appeared, if that was recent.
    var newShareAt: Date?
    /// Set by the store: someone other than you has commented since you last opened it from the widget.
    var hasNewComments = false

    private enum CodingKeys: String, CodingKey {
        case title, url, owner, updated, threads, openThreads, mentions, lastCommentAt, lastCommentBy, mentionPreview
    }

    var id: String { url }
    var isCollaboration: Bool { owner == "shared" || (threads ?? 0) > 0 }

    /// Days since you last changed one of your own artifacts; nil for shared ones or unknown dates.
    func daysSinceUpdate(now: Date = Date()) -> Int? {
        guard owner == "mine", let updated else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        guard let date = parser.date(from: updated) else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                               to: Calendar.current.startOfDay(for: now)).day
    }

    /// One of yours that you have worked on in the last couple of days.
    var isActive: Bool { (daysSinceUpdate() ?? 99) <= 2 }
}

/// Artifacts and their comment activity.
///
/// Claude Desktop keeps none of this on disk, and its sidebar does not expose it, so the widget
/// cannot fetch it. A Claude session writes a snapshot to
/// `~/Library/Application Support/ClaudePulse/artifacts.json` and this class just reads the file.
/// The data is therefore only as fresh as the last snapshot; `updatedAt` says how old that is.
final class ArtifactStore: ObservableObject {
    @Published private(set) var items: [ArtifactItem] = []
    @Published private(set) var updatedAt: Date?

    /// Called when the number of threads waiting on you goes up between snapshots.
    var onNewMentions: ((ArtifactItem) -> Void)?

    /// Called when an artifact someone shared with you shows up for the first time.
    var onNewShare: ((ArtifactItem) -> Void)?

    /// How long a newly shared artifact keeps its "new" label.
    private let newShareWindow: TimeInterval = 3 * 86_400
    private let knownKey = "knownSharedArtifacts"   // url -> first seen (seconds since 1970)
    private let dismissedKey = "dismissedMentions"  // url -> last comment time when you waved the tags off
    private let seenKey = "commentsSeenThrough"     // url -> last comment time when you last opened it

    // MARK: - What you have dealt with

    /// You opened the artifact from the widget. That settles a new share and catches you up on
    /// comments. It does not settle a tag: looking at a question is not answering it.
    func opened(_ item: ArtifactItem) {
        acknowledgeShare(item.url)
        var seen = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
        seen[item.url] = item.lastCommentAt?.timeIntervalSince1970 ?? 0
        UserDefaults.standard.set(seen, forKey: seenKey)
        reload()
    }

    /// You waved it off without opening. Clears a new share and any tags as they stand now;
    /// a later comment in that artifact brings the tags back.
    func dismiss(_ item: ArtifactItem) {
        acknowledgeShare(item.url)
        if (item.mentions ?? 0) > 0 {
            var dismissed = (UserDefaults.standard.dictionary(forKey: dismissedKey) as? [String: Double]) ?? [:]
            dismissed[item.url] = item.lastCommentAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            UserDefaults.standard.set(dismissed, forKey: dismissedKey)
        }
        reload()
    }

    private func acknowledgeShare(_ url: String) {
        var known = (UserDefaults.standard.dictionary(forKey: knownKey) as? [String: Double]) ?? [:]
        guard let first = known[url], first > 0 else { return }
        known[url] = 0  // known, and no longer new
        UserDefaults.standard.set(known, forKey: knownKey)
    }

    private func reload() {
        lastModified = nil
        load()
    }

    /// Diagnostic: walks the share, tag and comment rules against the current snapshot and reports
    /// counts at each step. Every preference it touches is put back before it returns.
    func debugLifecycle() -> String {
        let defaults = UserDefaults.standard
        let keys = [knownKey, dismissedKey, seenKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            reload()
        }
        func counts() -> String {
            "new shares \(items.filter { $0.newShareAt != nil }.count), tagged \(items.filter { ($0.mentions ?? 0) > 0 }.count), new comments \(items.filter { $0.hasNewComments }.count)"
        }
        reload()
        var out = ["start: \(counts())"]

        if let share = items.first(where: { $0.newShareAt != nil }) {
            opened(share)
            out.append("after opening a new share: \(counts())")
        } else if let shared = items.first(where: { $0.owner == "shared" }) {
            // No real new share right now: make one, then open it.
            var known = (defaults.dictionary(forKey: knownKey) as? [String: Double]) ?? [:]
            known[shared.url] = Date().timeIntervalSince1970
            defaults.set(known, forKey: knownKey)
            reload()
            out.append("with a simulated new share: \(counts())")
            if let share = items.first(where: { $0.url == shared.url }) { opened(share) }
            out.append("after opening it: \(counts())")
        }

        if let tagged = items.first(where: { ($0.mentions ?? 0) > 0 }) {
            opened(tagged)
            out.append("after opening a tagged artifact (tag should stay): \(counts())")
            dismiss(tagged)
            out.append("after dismissing it: \(counts())")
            var dismissed = (defaults.dictionary(forKey: dismissedKey) as? [String: Double]) ?? [:]
            dismissed[tagged.url] = (dismissed[tagged.url] ?? 0) - 3_600
            defaults.set(dismissed, forKey: dismissedKey)
            reload()
            out.append("after a later comment arrives (tag should return): \(counts())")
        } else {
            out.append("no tagged artifact in the snapshot, so the tag rules were not exercised")
        }

        if let commented = items.first(where: { $0.lastCommentAt != nil && $0.lastCommentBy != "You" }) {
            var seen = (defaults.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
            seen[commented.url] = (commented.lastCommentAt?.timeIntervalSince1970 ?? 0) - 3_600
            defaults.set(seen, forKey: seenKey)
            reload()
            out.append("with a comment newer than your last look: \(counts())")
            if let item = items.first(where: { $0.url == commented.url }) { opened(item) }
            out.append("after opening it: \(counts())")
        } else {
            out.append("no artifact with someone else's comment, so the new-comment rule was not exercised")
        }
        return out.joined(separator: "\n")
    }

    private struct Snapshot: Decodable {
        var updatedAt: Date?
        var artifacts: [ArtifactItem]
    }

    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudePulse/artifacts.json")
    private var timer: Timer?
    private var lastModified: Date?
    private var loadedOnce = false

    func start() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.load() }
    }

    private func load() {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != lastModified else { return }
        lastModified = modified
        guard let data = try? Data(contentsOf: file) else {
            items = []
            updatedAt = nil
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }

        let before = Dictionary(items.map { ($0.url, $0.mentions ?? 0) }, uniquingKeysWith: { a, _ in a })

        // Remember every shared artifact the first time it is seen. The very first snapshot only
        // seeds that record: everything in it was shared before the widget existed, so none is "new".
        let defaults = UserDefaults.standard
        let hadRecord = defaults.object(forKey: knownKey) != nil
        var known = (defaults.dictionary(forKey: knownKey) as? [String: Double]) ?? [:]
        let now = Date()
        var arrivals: [ArtifactItem] = []
        var artifacts = snapshot.artifacts
        for i in artifacts.indices where artifacts[i].owner == "shared" {
            let url = artifacts[i].url
            if known[url] == nil {
                known[url] = hadRecord ? now.timeIntervalSince1970 : 0
                if hadRecord { arrivals.append(artifacts[i]) }
            }
            if let first = known[url], first > 0, now.timeIntervalSince1970 - first < newShareWindow {
                artifacts[i].newShareAt = Date(timeIntervalSince1970: first)
            }
        }
        defaults.set(known, forKey: knownKey)

        // Tags you waved off stay quiet until someone comments again. Comments by other people
        // since you last opened the artifact are flagged as new; the first sighting is the baseline.
        var dismissed = (defaults.dictionary(forKey: dismissedKey) as? [String: Double]) ?? [:]
        var seen = (defaults.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
        for i in artifacts.indices {
            let url = artifacts[i].url
            let last = artifacts[i].lastCommentAt?.timeIntervalSince1970 ?? 0
            if let waved = dismissed[url] {
                if last <= waved { artifacts[i].mentions = 0 } else { dismissed[url] = nil }
            }
            if let through = seen[url] {
                artifacts[i].hasNewComments = last > through + 1 && artifacts[i].lastCommentBy != "You"
            } else {
                seen[url] = last
            }
        }
        defaults.set(dismissed, forKey: dismissedKey)
        defaults.set(seen, forKey: seenKey)

        // Tags waiting on you, then new shares, then fresh comments, your own recent work, the rest.
        func rank(_ a: ArtifactItem) -> Int {
            if (a.mentions ?? 0) > 0 { return 0 }
            if a.newShareAt != nil { return 1 }
            if a.hasNewComments { return 2 }
            if a.isActive { return 3 }
            return 4
        }
        let sorted = artifacts.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if rank(a) == 3 { return (a.updated ?? "") > (b.updated ?? "") }
            let ca = a.lastCommentAt ?? .distantPast, cb = b.lastCommentAt ?? .distantPast
            if ca != cb { return ca > cb }
            return (a.updated ?? "") > (b.updated ?? "")
        }
        if loadedOnce {
            for item in sorted where (item.mentions ?? 0) > (before[item.url] ?? 0) {
                onNewMentions?(item)
            }
        }
        arrivals.forEach { onNewShare?($0) }
        loadedOnce = true
        items = sorted
        updatedAt = snapshot.updatedAt
    }
}
