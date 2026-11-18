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

        // Tags waiting on you, then new shares, then your own recent work, then comment activity.
        func rank(_ a: ArtifactItem) -> Int {
            if (a.mentions ?? 0) > 0 { return 0 }
            if a.newShareAt != nil { return 1 }
            if a.isActive { return 2 }
            return 3
        }
        let sorted = artifacts.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if rank(a) == 2 { return (a.updated ?? "") > (b.updated ?? "") }
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
