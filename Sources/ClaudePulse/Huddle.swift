import AppKit
import Combine
import Foundation

// MARK: - Model

/// One step of an agent's own checklist, as Claude wrote it with its plan or todo tool.
struct HuddleStep: Equatable, Identifiable {
    enum Status: String { case pending, inProgress = "in_progress", completed }
    var id: Int
    var text: String
    var status: Status
}

/// The last shell command an agent ran, with the tail of what it printed.
struct HuddleCommand: Equatable {
    var toolUseId: String
    var command: String
    var description: String?
    /// Nil while the command is still running: Claude only writes the output once it ends.
    var output: String?
    var failed = false
    var startedAt: Date
}

/// A tool call Claude has made and not yet had a result for.
struct HuddleToolCall: Equatable {
    var id: String
    var name: String
    var input: [String: AnyHashable]
    var at: Date
}

/// A question from Claude's AskUserQuestion tool.
struct HuddleQuestion: Equatable, Identifiable {
    struct Option: Equatable, Identifiable {
        var id: String { label }
        var label: String
        var detail: String?
    }
    var id: String { question }
    var header: String?
    var question: String
    var options: [Option]
    var multiSelect: Bool
}

/// A permission request a Claude Code process has handed to Pulse through the hook. The hook
/// waits for an answer file; Claude's own prompt stays up meanwhile, and whichever is answered
/// first wins.
struct HuddleRequest: Equatable, Identifiable {
    var id: String
    var pid: Int32
    var sessionId: String
    var cwd: String
    var toolName: String
    var toolInput: [String: AnyHashable]
    var createdAt: Date

    var isQuestion: Bool { toolName == "AskUserQuestion" }
    var questions: [HuddleQuestion] { HuddleTranscript.questions(from: toolInput) }
}

/// What the huddle shows for one Claude Code agent.
struct HuddleAgent: Identifiable, Equatable {
    enum Need: Equatable {
        case none
        /// A tool call is waiting for approval. `answerable` when the hook has handed it to Pulse.
        case permission(summary: String, detail: String?, request: HuddleRequest?)
        /// An AskUserQuestion is open. Answerable when the hook has handed it to Pulse.
        case question([HuddleQuestion], request: HuddleRequest?)
        /// Claude ended its turn with a question. Only Claude can take the reply.
        case closingQuestion(String)
    }

    let id: String
    var title: String
    var project: String
    var state: SessionState
    var activity: String
    var steps: [HuddleStep]
    var command: HuddleCommand?
    var need: Need
    var lastActivity: Date
    var openURL: URL?
    /// The session id Claude Code uses, which is what the transcript and the hook know it by.
    var cliSessionId: String?
    var colorIndex: Int

    var doneSteps: Int { steps.filter { $0.status == .completed }.count }
    var progress: Double {
        if !steps.isEmpty { return Double(doneSteps) / Double(steps.count) }
        return state == .working ? 0 : 1
    }
    var currentStep: HuddleStep? { steps.first { $0.status == .inProgress } }
    var needsYou: Bool { if case .none = need { return false } else { return true } }
    /// Waiting on a permission or question that only Claude can take, because the hook is not in this session.
    var waitsWithoutHook: Bool {
        switch need {
        case .permission(_, _, nil), .question(_, nil): return true
        default: return false
        }
    }
}

// MARK: - Transcript reader

/// Reads a Claude Code transcript incrementally and keeps what the huddle needs: the checklist,
/// the tool calls still open, the last shell command and its output. Not thread-safe.
final class HuddleTranscript {
    private(set) var steps: [HuddleStep] = []
    private(set) var open: [String: HuddleToolCall] = [:]
    private(set) var openOrder: [String] = []
    private(set) var command: HuddleCommand?
    private(set) var lastAction: String?
    private(set) var lastActionAt: Date?
    /// The question in Claude's closing wrap-up, cleared once anything new is sent.
    private(set) var closingAsk: String?

    private var offset: UInt64 = 0
    private let path: String
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(path: String) { self.path = path }

    /// Reads whatever was appended since the last call.
    func refresh() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size < offset { reset() }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        // A long session's history is not needed in full: start near the end on first read.
        if offset == 0, size > 6_000_000 { offset = size - 6_000_000 }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let chunk = try? handle.readToEnd(), !chunk.isEmpty,
              let lastNewline = chunk.lastIndex(of: 0x0A) else { return }
        let complete = chunk[chunk.startIndex...lastNewline]
        offset += UInt64(complete.count)
        for line in complete.split(separator: 0x0A) { absorb(Data(line)) }
    }

    private func reset() {
        offset = 0
        steps = []
        open = [:]
        openOrder = []
        command = nil
        lastAction = nil
        closingAsk = nil
    }

    private static let assistantTag = Data("\"type\":\"assistant\"".utf8)
    private static let userTag = Data("\"type\":\"user\"".utf8)
    private static let sidechainTag = Data("\"isSidechain\":true".utf8)

    func absorb(_ line: Data) {
        let isAssistant = line.range(of: Self.assistantTag) != nil
        let isUser = !isAssistant && line.range(of: Self.userTag) != nil
        guard isAssistant || isUser, line.range(of: Self.sidechainTag) == nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = obj["message"] as? [String: Any]
        else { return }
        let at = (obj["timestamp"] as? String).flatMap { Self.iso.date(from: $0) } ?? Date()
        if isAssistant {
            for block in (message["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = (block["input"] as? [String: Any]) ?? [:]
                toolUse(id: id, name: name, input: input, at: at)
            }
        } else if let blocks = message["content"] as? [[String: Any]] {
            var sawResult = false
            for block in blocks where block["type"] as? String == "tool_result" {
                sawResult = true
                guard let id = block["tool_use_id"] as? String else { continue }
                open[id] = nil
                openOrder.removeAll { $0 == id }
                if command?.toolUseId == id {
                    command?.output = Self.text(of: block["content"])
                    command?.failed = (block["is_error"] as? Bool) == true
                }
            }
            if !sawResult { newPrompt() }
        } else if message["content"] is String {
            newPrompt()
        }
    }

    /// You sent the session something: whatever it asked before is answered.
    private func newPrompt() {
        closingAsk = nil
        open = [:]
        openOrder = []
    }

    private func toolUse(id: String, name: String, input: [String: Any], at: Date) {
        if name.hasSuffix("wrap_up") {
            let ask = (input["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            closingAsk = ask?.isEmpty == false ? ask : nil
            // Claude Desktop ticks the whole checklist off when a turn wraps up.
            for i in steps.indices { steps[i].status = .completed }
            return
        }
        closingAsk = nil
        if name.hasSuffix("update_plan") { applyPlan(input) }
        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            steps = todos.enumerated().map { i, t in
                let status = HuddleStep.Status(rawValue: (t["status"] as? String) ?? "") ?? .pending
                let text = status == .inProgress ? ((t["activeForm"] as? String) ?? (t["content"] as? String) ?? "")
                    : ((t["content"] as? String) ?? "")
                return HuddleStep(id: i, text: text, status: status)
            }
        }
        if name == "Bash", let cmd = input["command"] as? String {
            command = HuddleCommand(toolUseId: id, command: cmd, description: input["description"] as? String, startedAt: at)
        }
        open[id] = HuddleToolCall(id: id, name: name, input: Self.hashable(input), at: at)
        openOrder.append(id)
        if !name.hasSuffix("update_plan") {
            lastAction = Self.describe(name: name, input: input)
            lastActionAt = at
        }
    }

    /// Mirrors how Claude's plan tool edits its list: a whole new list, `advance`, `done` and `start`.
    private func applyPlan(_ input: [String: Any]) {
        if let items = input["items"] as? [[String: Any]] {
            steps = items.enumerated().map { i, item in
                HuddleStep(id: i, text: (item["content"] as? String) ?? "",
                           status: HuddleStep.Status(rawValue: (item["status"] as? String) ?? "") ?? .pending)
            }
        }
        if (input["advance"] as? Bool) == true {
            if let i = steps.firstIndex(where: { $0.status == .inProgress }) { steps[i].status = .completed }
            if let next = steps.firstIndex(where: { $0.status == .pending }) { steps[next].status = .inProgress }
        }
        for n in (input["done"] as? [NSNumber]) ?? [] {
            let i = n.intValue - 1
            if steps.indices.contains(i) { steps[i].status = .completed }
        }
        if let n = (input["start"] as? NSNumber)?.intValue, steps.indices.contains(n - 1) {
            for i in steps.indices where steps[i].status == .inProgress { steps[i].status = .completed }
            steps[n - 1].status = .inProgress
        }
    }

    /// The open AskUserQuestion, if Claude is waiting on one.
    var openQuestion: [HuddleQuestion]? {
        guard let id = openOrder.last(where: { open[$0]?.name == "AskUserQuestion" }), let call = open[id] else { return nil }
        let q = Self.questions(from: call.input)
        return q.isEmpty ? nil : q
    }

    /// The most recent tool call still waiting, the likeliest one to be stuck on a permission prompt.
    var latestOpenCall: HuddleToolCall? {
        openOrder.last.flatMap { open[$0] }
    }

    // MARK: Helpers

    static func questions(from input: [String: AnyHashable]) -> [HuddleQuestion] {
        guard let list = input["questions"] as? [[String: AnyHashable]] else { return [] }
        return list.compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = ((q["options"] as? [[String: AnyHashable]]) ?? []).compactMap { o -> HuddleQuestion.Option? in
                guard let label = o["label"] as? String else { return nil }
                return .init(label: label, detail: o["description"] as? String)
            }
            return HuddleQuestion(header: q["header"] as? String, question: text, options: options,
                                  multiSelect: (q["multiSelect"] as? Bool) ?? false)
        }
    }

    static func hashable(_ value: [String: Any]) -> [String: AnyHashable] {
        (try? JSONSerialization.data(withJSONObject: value)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: AnyHashable]
        } ?? [:]
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static func describe(name: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        }
        switch name {
        case "Bash":
            if let d = (input["description"] as? String), !d.isEmpty { return d }
            return "Running " + ((input["command"] as? String).map { String($0.prefix(60)) } ?? "a command")
        case "Read": return "Reading \(file())"
        case "Edit", "MultiEdit": return "Editing \(file())"
        case "Write": return "Writing \(file())"
        case "NotebookEdit": return "Editing \(file("notebook_path"))"
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch": return "Reading a web page"
        case "WebSearch": return "Searching the web"
        case "Agent", "Task": return (input["description"] as? String).map { "Agent: \($0)" } ?? "Running an agent"
        case "AskUserQuestion": return "Asking you a question"
        case "TodoWrite": return "Updating its checklist"
        case "Skill": return "Using the \((input["skill"] as? String) ?? "") skill"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                return "Using " + (parts.last.map(String.init)?.replacingOccurrences(of: "-", with: " ") ?? name)
            }
            return "Using \(name)"
        }
    }

    /// One line for a permission card: "Bash: npm test", "Edit: Views.swift".
    static func summary(tool: String, input: [String: AnyHashable]) -> (String, String?) {
        switch tool {
        case "Bash":
            return ("Bash: " + ((input["command"] as? String) ?? ""), input["description"] as? String)
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            return ("\(tool): " + (path as NSString).lastPathComponent, path)
        case "WebFetch":
            return ("WebFetch: " + ((input["url"] as? String) ?? ""), input["prompt"] as? String)
        default:
            let compact = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ("\(tool): " + String(compact.prefix(160)), nil)
        }
    }
}

// MARK: - Store

/// Builds the huddle from the sessions Pulse already tracks, their transcripts, and the permission
/// requests the hook hands over.
final class HuddleStore: ObservableObject {
    @Published private(set) var agents: [HuddleAgent] = []
    /// Requests answered from Pulse, so their cards close at once instead of on the next read.
    @Published private(set) var answered: Set<String> = []
    @Published private(set) var hookInstalled = HuddleHookInstaller.isInstalled()

    @Published var muted = UserDefaults.standard.bool(forKey: "huddleMuted") {
        didSet { UserDefaults.standard.set(muted, forKey: "huddleMuted") }
    }
    @Published var openOnNeed = Settings.bool("huddleOpenOnNeed", default: true) {
        didSet { UserDefaults.standard.set(openOnNeed, forKey: "huddleOpenOnNeed") }
    }

    /// Called on the main queue when an agent starts needing you (a new permission or question).
    var onNeed: ((HuddleAgent) -> Void)?

    private let sessions: SessionStore
    private let queue = DispatchQueue(label: "claude-pulse.huddle", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var transcripts: [String: HuddleTranscript] = [:]
    private var paths: [String: String] = [:]
    private var lastNeeds: [String: String] = [:]
    private var primed = false
    private var dismissed: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: "huddleDismissed") as? [String: Double]) ?? [:]
    private var cancellables = Set<AnyCancellable>()

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudePulse/huddle")
    }
    static var requestsDir: URL { root.appendingPathComponent("requests") }
    static var responsesDir: URL { root.appendingPathComponent("responses") }
    static var heartbeat: URL { root.appendingPathComponent("alive") }

    /// The running store, for the settings view.
    static weak var current: HuddleStore?
    /// Posted by the main panel's header button.
    static let toggleNotification = Notification.Name("ClaudePulseToggleHuddle")

    init(sessions: SessionStore) {
        self.sessions = sessions
    }

    func start() {
        for dir in [Self.requestsDir, Self.responsesDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(700), leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func refreshHookState() { hookInstalled = HuddleHookInstaller.isInstalled() }

    // MARK: Actions

    func allow(_ request: HuddleRequest) {
        respond(request, ["behavior": "allow"])
    }

    func deny(_ request: HuddleRequest) {
        respond(request, ["behavior": "deny", "message": "The user denied this from Claude Pulse."])
    }

    /// Sends the chosen options back as the AskUserQuestion answers, the way Claude's own prompt does.
    func answer(_ request: HuddleRequest, _ choices: [String: String]) {
        var input = request.toolInput as [String: Any]
        input["answers"] = choices
        respond(request, ["behavior": "allow", "updatedInput": input])
    }

    private func respond(_ request: HuddleRequest, _ decision: [String: Any]) {
        let body: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let url = Self.responsesDir.appendingPathComponent(request.id + ".json")
        let tmp = Self.responsesDir.appendingPathComponent("." + request.id + ".tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
        }
        answered.insert(request.id)
        queue.async { self.tick() }
    }

    /// Hides an agent's card until it does something new.
    func dismiss(_ agent: HuddleAgent) {
        dismissed[agent.id] = agent.lastActivity.timeIntervalSince1970
        if dismissed.count > 200 {
            dismissed = Dictionary(uniqueKeysWithValues: dismissed.sorted { $0.value > $1.value }.prefix(100).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(dismissed, forKey: "huddleDismissed")
        agents.removeAll { $0.id == agent.id }
    }

    func open(_ agent: HuddleAgent) {
        if let url = agent.openURL { NSWorkspace.shared.open(url) }
    }

    // MARK: Reading

    private func readRequests() -> [HuddleRequest] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.requestsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [HuddleRequest] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = d["id"] as? String,
                  let pid = (d["pid"] as? NSNumber)?.int32Value
            else { continue }
            // The hook is gone (Claude answered first, or it timed out): the request is over.
            guard kill(pid, 0) == 0 || errno == EPERM else {
                try? fm.removeItem(at: file)
                try? fm.removeItem(at: Self.responsesDir.appendingPathComponent(id + ".json"))
                continue
            }
            out.append(HuddleRequest(
                id: id, pid: pid,
                sessionId: (d["session_id"] as? String) ?? "",
                cwd: (d["cwd"] as? String) ?? "",
                toolName: (d["tool_name"] as? String) ?? "",
                toolInput: HuddleTranscript.hashable((d["tool_input"] as? [String: Any]) ?? [:]),
                createdAt: Date(timeIntervalSince1970: ((d["created"] as? NSNumber)?.doubleValue ?? 0))))
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// Sessions whose transcript was not found, and when it was last looked for.
    private var missing: [String: Date] = [:]

    private func locate(_ sessionId: String) -> String? {
        if let p = paths[sessionId] { return p }
        if let at = missing[sessionId], Date().timeIntervalSince(at) < 10 { return nil }
        missing[sessionId] = Date()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
        for sub in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let candidate = "\(dir)/\(sub)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: candidate) {
                paths[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    private func transcript(_ sessionId: String) -> HuddleTranscript? {
        if let t = transcripts[sessionId] { t.refresh(); return t }
        guard let path = locate(sessionId) else { return nil }
        let t = HuddleTranscript(path: path)
        transcripts[sessionId] = t
        t.refresh()
        return t
    }

    private static func colorIndex(_ id: String) -> Int {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % 6)
    }

    private func tick() {
        let fm = FileManager.default
        // With the huddle off there is nothing to show and nobody to answer: let the hook step aside.
        guard Settings.bool("showHuddle", default: false) else {
            try? fm.removeItem(at: Self.heartbeat)
            primed = false
            DispatchQueue.main.async { if !self.agents.isEmpty { self.agents = [] } }
            return
        }
        // Tell the hook Pulse is here to answer. Without a fresh beat it steps aside at once.
        if !fm.fileExists(atPath: Self.heartbeat.path) {
            fm.createFile(atPath: Self.heartbeat.path, contents: Data())
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: Self.heartbeat.path)

        let rows = DispatchQueue.main.sync { sessions.rows }
        let requests = readRequests()
        let answeredNow = DispatchQueue.main.sync { answered }
        let pendingRequests = requests.filter { !answeredNow.contains($0.id) }
        let now = Date()

        var built: [HuddleAgent] = []
        var claimed = Set<String>()
        for row in rows {
            let cli = row.cliSessionId
            let myRequests = pendingRequests.filter { $0.sessionId == cli }
            let recent = now.timeIntervalSince(row.lastActivity) < 45 * 60
            guard row.state != .idle || !myRequests.isEmpty || (row.isLive && recent) else { continue }
            if !myRequests.isEmpty { claimed.insert(cli ?? "") }
            let t = cli.flatMap { transcript($0) }
            built.append(agent(for: row, transcript: t, requests: myRequests, now: now))
        }
        // Requests from sessions Pulse does not list (a terminal session it has not read yet).
        for (sid, reqs) in Dictionary(grouping: pendingRequests.filter { !claimed.contains($0.sessionId) }, by: \.sessionId) {
            let t = transcript(sid)
            let cwd = reqs.first?.cwd ?? ""
            let row = SessionRow(id: sid, title: (cwd as NSString).lastPathComponent, project: (cwd as NSString).lastPathComponent,
                                 cwd: cwd, model: "", state: .needsInput, waitingFor: nil, lastActivity: reqs.last?.createdAt ?? now,
                                 desktopId: nil, cliSessionId: sid, isLive: true, tokens: TokenTotals())
            built.append(agent(for: row, transcript: t, requests: reqs, now: now))
        }

        // A dismissed card stays away until the agent does something new or needs you anew.
        built = built.filter { a in
            guard let at = dismissed[a.id] else { return true }
            if case .permission(_, _, let r?) = a.need, r.createdAt.timeIntervalSince1970 > at { return true }
            if case .question(_, let r?) = a.need, r.createdAt.timeIntervalSince1970 > at { return true }
            return a.lastActivity.timeIntervalSince1970 > at + 1
        }
        built.sort { a, b in
            if a.needsYou != b.needsYou { return a.needsYou }
            if a.state != b.state { return a.state < b.state }
            return a.lastActivity > b.lastActivity
        }

        // News: an agent that newly needs you.
        var fresh: [HuddleAgent] = []
        var needs: [String: String] = [:]
        for a in built {
            let key: String
            switch a.need {
            case .none: continue
            case .permission(let s, _, let r): key = "p:" + (r?.id ?? s)
            case .question(let q, let r): key = "q:" + (r?.id ?? q.first?.question ?? "")
            case .closingQuestion(let q): key = "c:" + q
            }
            needs[a.id] = key
            if primed, lastNeeds[a.id] != key { fresh.append(a) }
        }
        lastNeeds = needs
        primed = true

        let liveIds = Set(requests.map(\.id))
        DispatchQueue.main.async {
            if self.agents != built { self.agents = built }
            let stillAnswered = self.answered.intersection(liveIds)
            if stillAnswered != self.answered { self.answered = stillAnswered }
            for a in fresh { self.onNeed?(a) }
        }
    }

    private func agent(for row: SessionRow, transcript t: HuddleTranscript?, requests: [HuddleRequest], now: Date) -> HuddleAgent {
        var need = HuddleAgent.Need.none
        if let r = requests.last(where: { $0.isQuestion }) {
            need = .question(r.questions, request: r)
        } else if let r = requests.last {
            let (s, d) = HuddleTranscript.summary(tool: r.toolName, input: r.toolInput)
            need = .permission(summary: s, detail: d, request: r)
        } else if row.state == .needsInput {
            if let q = t?.openQuestion {
                need = .question(q, request: nil)
            } else if row.waitingFor != nil || row.prompt == "Approval needed", let call = t?.latestOpenCall {
                let (s, d) = HuddleTranscript.summary(tool: call.name, input: call.input)
                need = .permission(summary: s, detail: d, request: nil)
            } else if let ask = t?.closingAsk ?? row.prompt {
                need = .closingQuestion(ask)
            } else if row.waitingFor != nil {
                need = .permission(summary: "Approval needed", detail: nil, request: nil)
            }
        }

        let steps = t?.steps ?? []
        var activity: String
        switch need {
        case .permission: activity = "needs permission"
        case .question, .closingQuestion: activity = "asks a question"
        case .none:
            if row.state == .working {
                activity = t?.latestOpenCall.map { HuddleTranscript.describe(name: $0.name, input: $0.input) }
                    ?? steps.first { $0.status == .inProgress }?.text
                    ?? t?.lastAction ?? "Thinking"
            } else if row.state == .needsYou {
                activity = "Done. Get back to me"
            } else {
                activity = t?.lastAction.map { "Last: \($0)" } ?? "Idle"
            }
        }
        return HuddleAgent(
            id: row.id, title: row.title, project: row.project, state: row.state, activity: activity,
            steps: steps, command: t?.command, need: need, lastActivity: row.lastActivity,
            openURL: row.openURL, cliSessionId: row.cliSessionId, colorIndex: Self.colorIndex(row.id))
    }
}

// MARK: - Hook installation

/// Adds or removes Pulse's PermissionRequest hook in `~/.claude/settings.json`, which every
/// Claude Code session (Claude Desktop's included) reads when it starts.
enum HuddleHookInstaller {
    static let marker = "--huddle-hook"
    static var settingsURL: URL {
        // Tests point this at a copy instead of the real file.
        if let path = ProcessInfo.processInfo.environment["PULSE_CLAUDE_SETTINGS"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// `ClaudePulse --huddle-install-test on|off`: installs or removes the hook and prints the result.
    static func runTestIfRequested() {
        guard let i = CommandLine.arguments.firstIndex(of: "--huddle-install-test"),
              CommandLine.arguments.count > i + 1 else { return }
        let error = install(CommandLine.arguments[i + 1] == "on")
        print(error ?? "ok", isInstalled() ? "installed" : "not installed")
        exit(error == nil ? 0 : 1)
    }

    static var command: String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "'\(exe.replacingOccurrences(of: "'", with: "'\\''"))' \(marker)"
    }

    private static func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isInstalled() -> Bool {
        guard let hooks = load()?["hooks"] as? [String: Any],
              let list = hooks["PermissionRequest"] as? [[String: Any]] else { return false }
        return list.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    /// Returns an error message, or nil on success.
    @discardableResult
    static func install(_ on: Bool) -> String? {
        guard var settings = load() else { return "~/.claude/settings.json isn't valid JSON, so Pulse left it alone." }
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var list = (hooks["PermissionRequest"] as? [[String: Any]]) ?? []
        // Drop any earlier copy of ours, wherever the app lived then.
        list = list.compactMap { entry in
            var e = entry
            let kept = ((e["hooks"] as? [[String: Any]]) ?? []).filter { ($0["command"] as? String)?.contains(marker) != true }
            if kept.isEmpty { return nil }
            e["hooks"] = kept
            return e
        }
        if on {
            list.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 600]]])
        }
        if list.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = list }
        if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: settingsURL.path) {
                let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.pulse-backup")
                try? fm.removeItem(at: backup)
                try? fm.copyItem(at: settingsURL, to: backup)
            }
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: settingsURL, options: .atomic)
            return nil
        } catch {
            return "Couldn't write ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }
}
