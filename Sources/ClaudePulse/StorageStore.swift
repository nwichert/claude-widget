import AppKit
import Combine
import Foundation

/// Where Claude's disk space goes on this Mac, and what can safely be given back.
///
/// Everything that can be cleaned is moved to the Trash, never deleted outright, so a mistake can
/// be undone until the Trash is emptied. What Claude needs to run (the Cowork VM, the Claude Code
/// version in use, transcripts) is shown but never offered for cleaning.
final class StorageStore: ObservableObject {
    static let shared = StorageStore()

    enum Action: Equatable {
        /// Move these paths to the Trash.
        case trash([URL])
        /// `git worktree remove` this worktree from the repository it belongs to. Git refuses if
        /// it has changes or untracked files, so nothing unsaved is lost.
        case removeWorktree(repo: URL, path: URL)
    }

    struct Item: Identifiable, Equatable {
        var id: String
        var name: String
        var detail: String
        var bytes: Int64
        /// What cleaning would do; nil when this is shown for information only.
        var action: Action?
        var actionLabel: String = "Clean"
        /// The Claude app has these files open, so it must be quit first.
        var needsClaudeQuit = false
        /// Why it cannot be cleaned, when that is worth saying.
        var note: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var total: Int64 = 0
    @Published private(set) var updatedAt: Date?
    @Published private(set) var scanning = false
    /// The outcome of the last clean, e.g. "Moved 670 MB to the Trash".
    @Published private(set) var lastResult: String?

    private let queue = DispatchQueue(label: "claude-pulse.storage", qos: .utility)
    private var timer: DispatchSourceTimer?

    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static var claudeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: .seconds(1_800), leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    func refresh() { queue.async { self.scan() } }

    func clean(_ item: Item) {
        guard let action = item.action else { return }
        queue.async {
            let result: String
            switch action {
            case .trash(let urls):
                var moved: Int64 = 0
                var failed = 0
                for url in urls {
                    let size = Self.size(of: url)
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        moved += size
                    } catch { failed += 1 }
                }
                result = "Moved \(Self.format(moved)) to the Trash" + (failed > 0 ? "; \(failed) could not be moved" : "") + ". Empty the Trash to free the space."
            case .removeWorktree(let repo, let path):
                let size = Self.size(of: path)
                let out = Self.git(repo, ["worktree", "remove", path.path])
                result = out.ok ? "Removed the \(path.lastPathComponent) worktree (\(Self.format(size))). Its branch is kept."
                    : "Git kept \(path.lastPathComponent): \(out.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            DispatchQueue.main.async { self.lastResult = result }
            self.scan()
        }
    }

    // MARK: - Scanning

    private func scan() {
        DispatchQueue.main.async { self.scanning = true }
        let (items, total) = Self.measure()
        DispatchQueue.main.async {
            self.items = items
            self.total = total
            self.updatedAt = Date()
            self.scanning = false
        }
    }

    /// Diagnostic: what a scan finds, one item per line. Cleans nothing.
    static func debugScan() -> String {
        let (items, total) = measure()
        return "total \(format(total))\n" + items.map {
            "\($0.name)\t\(format($0.bytes))\t\($0.action == nil ? "info" : $0.actionLabel)\t\($0.detail)"
        }.joined(separator: "\n") + "\n"
    }

    private static func measure() -> ([Item], Int64) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/Claude")
        var out: [Item] = []

        // The Cowork VM: the bulk of it, and Claude needs it.
        let vm = support.appendingPathComponent("vm_bundles")
        out.append(Item(id: "vm", name: "Cowork VM", detail: "The Linux machine Cowork tasks run in",
                        bytes: size(of: vm), note: "Claude needs this to run Cowork; it would download it again."))

        // Claude Code versions other than the one `claude` runs.
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        let current = (try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".local/bin/claude").path))
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        let installed = ((try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        let old = current == nil ? [] : installed.filter { $0.lastPathComponent != current }
        let oldBytes = old.reduce(Int64(0)) { $0 + size(of: $1) }
        out.append(Item(id: "versions", name: "Old Claude Code versions",
                        detail: old.isEmpty ? "Only the version in use (\(current ?? "unknown"))"
                            : "\(old.map(\.lastPathComponent).joined(separator: ", ")); in use: \(current ?? "?")",
                        bytes: oldBytes, action: old.isEmpty ? nil : .trash(old)))

        // Caches the desktop app and the CLI rebuild on their own.
        let appCaches = ["Cache", "Code Cache", "GPUCache", "GraphiteDawnCache", "DawnGraphiteCache", "DawnWebGPUCache"]
            .map { support.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        let cliCache = home.appendingPathComponent("Library/Caches/claude-cli-nodejs")
        let appBytes = appCaches.reduce(Int64(0)) { $0 + size(of: $1) }
        out.append(Item(id: "appcache", name: "Claude app caches", detail: "Web and GPU caches; rebuilt as needed",
                        bytes: appBytes, action: appBytes > 0 ? .trash(appCaches) : nil,
                        needsClaudeQuit: true))
        if fm.fileExists(atPath: cliCache.path) {
            let bytes = size(of: cliCache)
            out.append(Item(id: "clicache", name: "Claude Code cache", detail: "CLI cache and MCP logs",
                            bytes: bytes, action: bytes > 0 ? .trash([cliCache]) : nil))
        }

        // Logs more than a week old.
        let logs = home.appendingPathComponent("Library/Logs/Claude")
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let oldLogs = ((try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()) < weekAgo }
        let logBytes = oldLogs.reduce(Int64(0)) { $0 + size(of: $1) }
        out.append(Item(id: "logs", name: "Old logs", detail: "Claude app logs over a week old",
                        bytes: logBytes, action: oldLogs.isEmpty ? nil : .trash(oldLogs)))

        // Worktrees Claude Code made, one row each.
        out += worktrees(home: home)

        // Kept for reference, never cleaned here.
        let projects = home.appendingPathComponent(".claude/projects")
        out.append(Item(id: "transcripts", name: "Session transcripts", detail: "Your Code session history",
                        bytes: size(of: projects), note: "Resume and Pulse's usage figures read these."))
        let extras = [".claude/plugins", ".claude/skills"].map { home.appendingPathComponent($0) }
        out.append(Item(id: "plugins", name: "Plugins and skills", detail: "Installed in ~/.claude",
                        bytes: extras.reduce(Int64(0)) { $0 + size(of: $1) },
                        note: "Remove ones you no longer use from Claude itself."))

        let total = size(of: support) + size(of: home.appendingPathComponent(".claude"))
            + size(of: home.appendingPathComponent(".local/share/claude")) + size(of: cliCache)
            + size(of: logs) + out.filter { $0.id.hasPrefix("wt:") }.reduce(Int64(0)) { $0 + $1.bytes }
        return (out.filter { $0.bytes > 0 || $0.action != nil }, total)
    }

    /// Git worktrees under a `.claude/worktrees` folder, found through the repositories that
    /// have Code sessions. A worktree with changes is listed but not offered for removal.
    private static func worktrees(home: URL) -> [Item] {
        let fm = FileManager.default
        let projects = home.appendingPathComponent(".claude/projects")
        var repos: Set<String> = []
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            guard let file = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .first(where: { $0.pathExtension == "jsonl" }),
                  let cwd = firstCwd(file) else { continue }
            // A worktree's own sessions point back at the repository that holds it.
            let root = cwd.components(separatedBy: "/.claude/worktrees/").first ?? cwd
            if fm.fileExists(atPath: root + "/.git") { repos.insert(root) }
        }
        var out: [Item] = []
        for repo in repos.sorted() {
            let repoURL = URL(fileURLWithPath: repo)
            let list = git(repoURL, ["worktree", "list", "--porcelain"])
            guard list.ok else { continue }
            for line in list.text.split(separator: "\n") where line.hasPrefix("worktree ") {
                let path = String(line.dropFirst("worktree ".count))
                guard path.contains("/.claude/worktrees/"), fm.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path)
                let dirty = !git(url, ["status", "--porcelain"]).text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                out.append(Item(id: "wt:" + path, name: "Worktree · \(url.lastPathComponent)",
                                detail: repoURL.lastPathComponent + (dirty ? " · has uncommitted changes" : " · clean"),
                                bytes: size(of: url),
                                action: dirty ? nil : .removeWorktree(repo: repoURL, path: url),
                                actionLabel: "Remove",
                                note: dirty ? "Commit or discard its changes first." : nil))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    private static func firstCwd(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64_000), let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst(7).dropLast())
    }

    private static func git(_ dir: URL, _ args: [String]) -> (ok: Bool, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Space actually taken on disk, like `du`: sparse disk images count only what they use.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = walker?.nextObject() as? URL {
            if let v = try? file.resourceValues(forKeys: keys), v.isDirectory != true, v.isSymbolicLink != true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
