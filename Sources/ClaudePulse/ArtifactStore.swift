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

    var id: String { url }
    var isCollaboration: Bool { owner == "shared" || (threads ?? 0) > 0 }
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
        // Waiting on you first, then live collaborations by latest comment, then everything else.
        let sorted = snapshot.artifacts.sorted { a, b in
            let ma = a.mentions ?? 0, mb = b.mentions ?? 0
            if (ma > 0) != (mb > 0) { return ma > 0 }
            let ca = a.lastCommentAt ?? .distantPast, cb = b.lastCommentAt ?? .distantPast
            if ca != cb { return ca > cb }
            return (a.updated ?? "") > (b.updated ?? "")
        }
        if loadedOnce {
            for item in sorted where (item.mentions ?? 0) > (before[item.url] ?? 0) {
                onNewMentions?(item)
            }
        }
        loadedOnce = true
        items = sorted
        updatedAt = snapshot.updatedAt
    }
}
