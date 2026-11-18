import Foundation

struct GitInfo: Equatable {
    var branch: String
    var changed: Int
    var ahead: Int
    var behind: Int
    /// GitHub "owner/name" parsed from the origin remote, when there is one.
    var repo: String?
}

struct PRInfo: Equatable {
    var number: String
    var state: String  // as Claude Desktop last recorded it: OPEN, MERGED, CLOSED
    var url: String
}

/// Working-tree status per project folder, refreshed in the background at most every 20 seconds.
/// `info(for:)` never blocks: it returns the last known answer and schedules a refresh if stale.
final class GitReader {
    private let lock = NSLock()
    private var cache: [String: (at: Date, info: GitInfo?)] = [:]
    private var inFlight = Set<String>()
    private let work = DispatchQueue(label: "claude-pulse.git", qos: .utility, attributes: .concurrent)
    private let maxAge: TimeInterval = 20

    func info(for cwd: String) -> GitInfo? {
        guard !cwd.isEmpty else { return nil }
        lock.lock()
        let cached = cache[cwd]
        let stale = cached.map { Date().timeIntervalSince($0.at) > maxAge } ?? true
        let start = stale && inFlight.insert(cwd).inserted
        lock.unlock()
        if start {
            work.async { [weak self] in
                let info = Self.read(cwd)
                guard let self else { return }
                self.lock.lock()
                self.cache[cwd] = (Date(), info)
                self.inFlight.remove(cwd)
                self.lock.unlock()
            }
        }
        return cached?.info
    }

    private static func read(_ cwd: String) -> GitInfo? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // --no-optional-locks: a status check must never contend with a session's own git commands.
        p.arguments = ["--no-optional-locks", "-C", cwd, "status", "--porcelain=v2", "--branch"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }

        var info = GitInfo(branch: "", changed: 0, ahead: 0, behind: 0)
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                info.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { info.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { info.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                info.changed += 1
            }
        }
        guard !info.branch.isEmpty else { return nil }
        info.repo = githubRepo(cwd)
        return info
    }

    /// "https://github.com/owner/name.git" or "git@github.com:owner/name.git" -> "owner/name"
    private static func githubRepo(_ cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "remote", "get-url", "origin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              var url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let host = url.range(of: "github.com")
        else { return nil }
        url = String(url[host.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if url.hasSuffix(".git") { url.removeLast(4) }
        return url.split(separator: "/").count == 2 ? url : nil
    }
}
