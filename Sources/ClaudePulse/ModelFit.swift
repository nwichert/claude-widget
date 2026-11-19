import Combine
import Foundation

/// How each model's use in Code sessions divides by the weight of the work: quick turns (a short
/// reply, a couple of edits at most), heavy turns (subagents, long output, many edits) and
/// everyday work in between. Each kind suits a different model, so the split is a rough guide to
/// which model fits the work and what switching would free up on a per-model limit.
///
/// Read from the local transcripts under ~/.claude/projects, every ten minutes, re-reading only
/// the files that changed. Chats and Duet leave no local record, so they are not counted.
final class ModelFit: ObservableObject {
    static let shared = ModelFit()

    struct Share: Equatable {
        /// Fractions of the model's weighted tokens, 0...1; the rest is everyday work.
        var quick: Double
        var heavy: Double
        var turns: Int
        var everyday: Double { max(0, 1 - quick - heavy) }
    }

    /// By model family ("fable", "opus", "sonnet", "haiku"), for the week `weekStart` began.
    @Published private(set) var shares: [String: Share] = [:]

    private enum Weight { case quick, everyday, heavy }
    private struct Message { var family: String; var cost: Double; var at: String; var weight: Weight; var turn: Int }
    private struct FileResult { var modified: Date; var size: Int; var messages: [Message] }

    private let queue = DispatchQueue(label: "claude-pulse.model-fit", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cache: [String: FileResult] = [:]
    private var weekStart = Date().addingTimeInterval(-7 * 86_400)

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: .seconds(600), leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    /// The limit's week runs from its last reset; `resets` is Claude's wording, e.g. "Sat 6:00 PM".
    func setWeek(resets: String?) {
        guard let start = Self.lastReset(resets, now: Date()) else { return }
        queue.async {
            guard abs(start.timeIntervalSince(self.weekStart)) > 60 else { return }
            self.weekStart = start
            self.scan()
        }
    }

    /// The most recent moment matching "Sat 6:00 PM", or nil if the text is not in that shape.
    static func lastReset(_ resets: String?, now: Date) -> Date? {
        guard let resets else { return nil }
        let parts = resets.split(separator: " ", maxSplits: 1).map(String.init)
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        guard parts.count == 2, let weekday = days.firstIndex(of: String(parts[0].lowercased().prefix(3))) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        guard let time = formatter.date(from: parts[1]) else { return nil }
        let calendar = Calendar.current
        var wanted = calendar.dateComponents([.hour, .minute], from: time)
        wanted.weekday = weekday + 1
        return calendar.nextDate(after: now, matching: wanted, matchingPolicy: .nextTime, direction: .backward)
    }

    private func scan() {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let since = weekStart
        var seen: Set<String> = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= since else { continue }
                let size = values.fileSize ?? 0
                seen.insert(file.path)
                if let cached = cache[file.path], cached.modified == modified, cached.size == size { continue }
                // A transcript sits directly in its project's folder; anything deeper is a subagent's.
                let nested = file.deletingLastPathComponent().deletingLastPathComponent().path != root.path
                cache[file.path] = FileResult(modified: modified, size: size, messages: Self.read(file, subagent: nested))
            }
        }
        for path in cache.keys where !seen.contains(path) { cache[path] = nil }

        let iso = ISO8601DateFormatter()
        let from = String(iso.string(from: since).prefix(19))
        var total: [String: Double] = [:]
        var quick: [String: Double] = [:]
        var heavy: [String: Double] = [:]
        var turns: [String: Set<String>] = [:]
        for (path, result) in cache {
            for message in result.messages where message.at.prefix(19) >= from {
                total[message.family, default: 0] += message.cost
                if message.weight == .quick { quick[message.family, default: 0] += message.cost }
                if message.weight == .heavy { heavy[message.family, default: 0] += message.cost }
                turns[message.family, default: []].insert("\(path)#\(message.turn)")
            }
        }
        var shares: [String: Share] = [:]
        for (family, cost) in total where cost > 0 {
            shares[family] = Share(quick: (quick[family] ?? 0) / cost, heavy: (heavy[family] ?? 0) / cost,
                                   turns: turns[family]?.count ?? 0)
        }
        DispatchQueue.main.async { if self.shares != shares { self.shares = shares } }
    }

    /// One transcript's assistant messages, each marked with the weight of the turn it belongs to.
    private static func read(_ file: URL, subagent: Bool) -> [Message] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        let userMark = Data(#""type":"user""#.utf8)
        let toolResult = Data(#""tool_result""#.utf8)
        let usageMark = Data(#""usage""#.utf8)

        struct Turn {
            var messages: [String: (family: String, cost: Double, output: Int, at: String)] = [:]
            var edits = 0
            var heavy = false
        }
        var out: [Message] = []
        var turn = Turn()
        var index = 0
        func close() {
            let output = turn.messages.values.reduce(0) { $0 + $1.output }
            let weight: Weight = subagent || turn.heavy || turn.edits > 10 || output > 12_000 ? .heavy
                : turn.edits <= 2 && output <= 2_000 ? .quick : .everyday
            for message in turn.messages.values {
                out.append(Message(family: message.family, cost: message.cost, at: message.at, weight: weight, turn: index))
            }
            turn = Turn()
            index += 1
        }

        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? end + 1 : end
            // Cheap filters before paying for a JSON parse; transcripts hold large tool results.
            if line.range(of: userMark) != nil, line.range(of: toolResult) == nil {
                guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if d["type"] as? String == "user", d["isMeta"] as? Bool != true, d["isSidechain"] as? Bool != true {
                    close()
                }
                continue
            }
            guard line.range(of: usageMark) != nil,
                  let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  d["type"] as? String == "assistant",
                  let message = d["message"] as? [String: Any],
                  let id = message["id"] as? String,
                  let usage = message["usage"] as? [String: Any] else { continue }
            let model = (message["model"] as? String ?? "").lowercased()
            guard let family = ["fable", "mythos", "opus", "sonnet", "haiku"].first(where: model.contains) else { continue }
            func count(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
            // Roughly how the kinds of token compare in price: fresh input 1, cache writes 1.25,
            // cache reads 0.1, output 5.
            let cost = count("input_tokens") + 1.25 * count("cache_creation_input_tokens")
                + 0.1 * count("cache_read_input_tokens") + 5 * count("output_tokens")
            // A streamed reply is logged more than once; the last copy has the final counts.
            turn.messages[id] = (family, cost, Int(count("output_tokens")), d["timestamp"] as? String ?? "")
            if d["isSidechain"] as? Bool == true { turn.heavy = true }
            for block in (message["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_use" {
                switch block["name"] as? String ?? "" {
                case "Agent", "Task", "Workflow": turn.heavy = true
                case "Edit", "Write", "NotebookEdit": turn.edits += 1
                default: break
                }
            }
        }
        close()
        return out
    }
}
