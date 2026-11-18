import Foundation

/// Reads token usage out of Claude Code transcript files (`~/.claude/projects/<project>/<session>.jsonl`).
/// Each file is read incrementally: only bytes appended since the last pass are parsed.
/// Not thread-safe; call from one queue.
final class TokenTally {
    private struct Usage { var input = 0, output = 0, cacheRead = 0, context = 0 }

    private struct FileState {
        var offset: UInt64 = 0
        /// A streamed reply is logged several times under one message id; keep the latest figures per id.
        var perMessage: [String: Usage] = [:]
        var totals = TokenTotals()
    }

    private var files: [String: FileState] = [:]
    private var paths: [String: String] = [:]
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects").path
    private let needle = Data("\"usage\"".utf8)

    func totals(forSession sessionId: String) -> TokenTotals {
        guard let path = locate(sessionId) else { return TokenTotals() }
        return read(path)
    }

    private func locate(_ sessionId: String) -> String? {
        if let p = paths[sessionId] { return p }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for dir in dirs {
            let candidate = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
            if fm.fileExists(atPath: candidate) {
                paths[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    private func read(_ path: String) -> TokenTotals {
        var state = files[path] ?? FileState()
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size < state.offset { state = FileState() }  // file was rewritten
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else {
            files[path] = state
            return state.totals
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
            guard let chunk = try handle.readToEnd(), !chunk.isEmpty,
                  let lastNewline = chunk.lastIndex(of: 0x0A) else {
                files[path] = state
                return state.totals
            }
            // Only consume whole lines; a partial trailing line is picked up next pass.
            let complete = chunk[chunk.startIndex...lastNewline]
            state.offset += UInt64(complete.count)
            for line in complete.split(separator: 0x0A) where line.range(of: needle) != nil {
                absorb(line, into: &state)
            }
        } catch {
            // Leave state as it was; try again next pass.
        }
        files[path] = state
        return state.totals
    }

    private func absorb(_ line: Data, into state: inout FileState) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let fresh = int("input_tokens") + int("cache_creation_input_tokens")
        let u = Usage(input: fresh,
                      output: int("output_tokens"),
                      cacheRead: int("cache_read_input_tokens"),
                      context: fresh + int("cache_read_input_tokens"))

        let id = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
        if let old = state.perMessage[id] {
            state.totals.input -= old.input
            state.totals.output -= old.output
            state.totals.cacheRead -= old.cacheRead
        }
        state.perMessage[id] = u
        state.totals.input += u.input
        state.totals.output += u.output
        state.totals.cacheRead += u.cacheRead
        if (obj["isSidechain"] as? Bool) != true,
           let text = (message["content"] as? [[String: Any]])?
               .last(where: { $0["type"] as? String == "text" })?["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { state.totals.endsWithQuestion = trimmed.hasSuffix("?") }
        }
        if (obj["isSidechain"] as? Bool) != true, u.context > 0 {
            state.totals.context = u.context
            state.totals.peakContext = max(state.totals.peakContext, u.context)
        }
    }
}
