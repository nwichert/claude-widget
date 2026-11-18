import AppKit
import Combine
import Foundation

let claudeBundleID = "com.anthropic.claudefordesktop"

/// Polls Claude's local session files and publishes one row per session.
///
/// Sources (all undocumented internals, so every field is optional and a
/// missing one degrades the row instead of dropping it):
///  - `~/.claude/sessions/<pid>.json`: one per running Claude Code process, with live busy/idle status
///  - `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`: Claude Desktop's record per session
///  - `~/.claude/projects/**/<session>.jsonl`: transcripts, for token usage
final class SessionStore: ObservableObject {
    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var plan: PlanUsage?

    /// Called on the main queue when a session stops working while you were not looking at it.
    var onFinished: ((SessionRow) -> Void)?

    /// Called on the main queue, once per waiting spell, when a session has sat waiting past `reminderDelay`.
    var onReminder: ((SessionRow) -> Void)?

    /// Supplies the latest reading of Claude's sidebar, when Accessibility access allows one.
    var sidebar: (() -> ChatReader.Sidebar?)?

    /// Sessions that stopped while you were not looking, by id -> when. Claude Desktop's own
    /// "last focused" time keeps moving for the selected session even while you are in another
    /// app, so it cannot be trusted to say you saw a turn finish; this record can.
    private var pending: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: "pendingAttention") as? [String: Double]) ?? [:]
    /// Zero means reminders are off.
    private var reminderDelay: TimeInterval {
        Double(Settings.int(Settings.Key.remindMinutes, default: 15)) * 60
    }
    /// Session id -> the start of the waiting spell already reminded about.
    private var reminded: [String: Date] = [:]

    /// Sessions with no running process are listed if they were active this recently.
    private var recentWindow: TimeInterval {
        Double(Settings.int(Settings.Key.recentHours, default: 24)) * 3_600
    }
    private let git = GitReader()

    private let queue = DispatchQueue(label: "claude-pulse.reader", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let tally = TokenTally()
    private var desktopCache: [String: (mtime: Date, record: DesktopRecord?)] = [:]
    private var previous: [String: SessionState] = [:]

    /// Models seen with a prompt above 200k tokens, which only a 1M-token window allows.
    /// Remembered across launches so a fresh session on that model is measured against 1M too.
    private let largeWindowKey = "modelsWithLargeWindow"
    private lazy var largeWindowModels = Set(UserDefaults.standard.stringArray(forKey: largeWindowKey) ?? [])

    /// Claude does not record the window size anywhere readable, so it is inferred:
    /// 1M once this session or its model has been seen above 200k, otherwise 200k.
    private func window(for row: SessionRow) -> Int {
        if row.tokens.peakContext > 200_000 { return 1_000_000 }
        return !row.model.isEmpty && largeWindowModels.contains(row.model) ? 1_000_000 : 200_000
    }
    private var primed = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var liveDir: URL { home.appendingPathComponent(".claude/sessions") }
    private var appSupport: URL { home.appendingPathComponent("Library/Application Support/Claude") }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Clears a finished session's "done" flag without opening it. A later turn raises it again.
    func markSeen(_ row: SessionRow) {
        var seen = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
        seen[row.id] = row.lastActivity.timeIntervalSince1970
        // Keep the record from growing without bound.
        if seen.count > 200 {
            seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(100).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(seen, forKey: seenKey)
        if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].state = .idle }
        let id = row.id
        queue.async { self.pending[id] = nil }
    }

    private let seenKey = "seenFinishedAt"

    /// Render aid: shows the second row as finished so the "done" look can be checked on demand.
    func debugForceDone() {
        if rows.count > 1 { rows[1].state = .needsYou }
        if rows.count > 2 {
            rows[2].state = .needsInput
            rows[2].prompt = "Should the export include archived claims?"
        }
    }

    // MARK: - Records

    private struct LiveRecord {
        var sessionId: String
        var hostSessionId: String?
        var cwd: String
        var name: String?
        var status: String?
        var waitingFor: String?
        var updated: Date?
    }

    private struct DesktopRecord {
        var sessionId: String
        var cliSessionId: String?
        var title: String?
        var model: String?
        var cwd: String?
        var lastActivity: Date?
        var lastFocused: Date?
        var lastTurnEdge: Date?
        var archived: Bool
        var pr: PRInfo?
        /// Claude's own after-turn verdict: "completed", "blocked", ...
        var summaryCategory: String?
        var needsAction: String?
        /// Set when a scheduled task started this session rather than you.
        var scheduled = false
    }

    private static func date(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1_000)
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readLive() -> [LiveRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let d = Self.json(file),
                  let sessionId = d["sessionId"] as? String,
                  let pid = (d["pid"] as? NSNumber)?.int32Value,
                  d["spare"] == nil  // pre-warmed process nobody is using yet
            else { continue }
            // The file can outlive a crashed process.
            guard kill(pid, 0) == 0 || errno == EPERM else { continue }
            out.append(LiveRecord(
                sessionId: sessionId,
                hostSessionId: d["hostSessionId"] as? String,
                cwd: (d["cwd"] as? String) ?? "",
                name: d["name"] as? String,
                status: d["status"] as? String,
                waitingFor: d["waitingFor"] as? String,
                updated: Self.date(d["statusUpdatedAt"]) ?? Self.date(d["updatedAt"])))
        }
        return out
    }

    private func readDesktop() -> [DesktopRecord] {
        let fm = FileManager.default
        let root = appSupport.appendingPathComponent("claude-code-sessions")
        var out: [DesktopRecord] = []
        var seen = Set<String>()
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        for case let file as URL in walker {
            guard file.pathExtension == "json", file.lastPathComponent.hasPrefix("local_") else { continue }
            let path = file.path
            seen.insert(path)
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let cached = desktopCache[path], cached.mtime == mtime {
                if let r = cached.record { out.append(r) }
                continue
            }
            var record: DesktopRecord?
            if let d = Self.json(file), let id = d["sessionId"] as? String {
                record = DesktopRecord(
                    sessionId: id,
                    cliSessionId: d["cliSessionId"] as? String,
                    title: d["title"] as? String,
                    model: d["model"] as? String,
                    cwd: d["cwd"] as? String,
                    lastActivity: Self.date(d["lastActivityAt"]),
                    lastFocused: Self.date(d["lastFocusedAt"]),
                    lastTurnEdge: Self.date(d["lastTurnEdgeAt"]),
                    archived: (d["isArchived"] as? Bool) ?? false,
                    pr: (d["prs"] as? [[String: Any]])?.last.flatMap { p in
                        guard let url = p["url"] as? String else { return nil }
                        let number = (p["prNumber"] as? String) ?? (p["prNumber"] as? NSNumber)?.stringValue ?? ""
                        return PRInfo(number: number, state: (p["state"] as? String) ?? "", url: url)
                    })
                record?.scheduled = (d["scheduledTaskId"] as? String)?.isEmpty == false
                // Claude Desktop's after-turn verdict. Only trust it if it is about the latest message.
                if let summary = d["postTurnSummary"] as? [String: Any] {
                    let about = (d["postTurnSummaryFor"] as? String) ?? (summary["summarizes_uuid"] as? String)
                    let latest = d["lastAssistantUuid"] as? String
                    if about == nil || latest == nil || about == latest {
                        record?.summaryCategory = summary["status_category"] as? String
                        record?.needsAction = (summary["needs_action"] as? String)?.nonEmpty
                    }
                }
                // The question Claude left in its end-of-turn box. This is the main "asked you something"
                // signal: it is set when a turn closes with a question and cleared when the next turn starts.
                if let wrapUp = d["turnWrapUp"] as? [String: Any], let ask = wrapUp["needsUser"] as? String {
                    let failed = record?.summaryCategory == "failed"
                    let earlier = record?.needsAction
                    record?.summaryCategory = failed ? "failed" : "blocked"
                    record?.needsAction = ask.nonEmpty ?? earlier
                }
            }
            desktopCache[path] = (mtime, record)
            if let record { out.append(record) }
        }
        desktopCache = desktopCache.filter { seen.contains($0.key) }
        return out
    }

    private func readPlan() -> PlanUsage? {
        guard let d = Self.json(appSupport.appendingPathComponent("plan-usage-history.json")),
              let last = (d["samples"] as? [[String: Any]])?.last,
              let at = Self.date(last["t"]),
              let u = last["u"] as? [String: Any],
              let fh = (u["fh"] as? NSNumber)?.intValue,
              let sd = (u["sd"] as? NSNumber)?.intValue
        else { return nil }
        return PlanUsage(fiveHour: fh, sevenDay: sd, sampledAt: at)
    }

    // MARK: - Merge

    private func tick() {
        let live = readLive()
        let desktop = readDesktop()
        let now = Date()

        let claudeIsFront = DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
        }
        // The session Claude Desktop is showing: you can already see it, so it never "needs you".
        var onScreen: String? = claudeIsFront
            ? desktop.max { ($0.lastFocused ?? .distantPast) < ($1.lastFocused ?? .distantPast) }?.sessionId
            : nil
        // On the Claude (chat) tab no Code session is on screen, whatever was selected last.
        let side = sidebar?().flatMap { now.timeIntervalSince($0.at) < 15 ? $0 : nil }
        if side?.chatTab == true { onScreen = nil }

        var liveByHost: [String: LiveRecord] = [:]
        var liveByCli: [String: LiveRecord] = [:]
        for l in live {
            if let h = l.hostSessionId { liveByHost[h] = l }
            liveByCli[l.sessionId] = l
        }

        var built: [SessionRow] = []
        var claimed = Set<String>()
        var prByRow: [String: PRInfo] = [:]
        var promptByRow: [String: String] = [:]
        let remindAfter = reminderDelay

        for d in desktop where !d.archived {
            let l = liveByHost[d.sessionId] ?? d.cliSessionId.flatMap { liveByCli[$0] }
            if let l { claimed.insert(l.sessionId) }
            let activity = [d.lastActivity, d.lastTurnEdge, l?.updated].compactMap { $0 }.max() ?? .distantPast
            guard l != nil || now.timeIntervalSince(activity) < recentWindow else { continue }

            // A scheduled task's run is background plumbing: list it only while it is actually running
            // or stuck, never as a finished session waiting for you.
            if d.scheduled, l?.status != "busy", l?.status != "waiting", l?.waitingFor == nil { continue }

            let cwd = l?.cwd.nonEmpty ?? d.cwd ?? ""
            let cli = l?.sessionId ?? d.cliSessionId
            let totals = cli.map { tally.totals(forSession: $0) } ?? TokenTotals()
            let title = d.title?.nonEmpty ?? l?.name?.nonEmpty ?? (cwd as NSString).lastPathComponent
            let visible = d.sessionId == onScreen

            // Stopped mid-turn on a question or an approval. Two independent sources: the session's
            // own status file, and the label Claude's sidebar shows while its Code tab is open.
            let badge = side?.chatTab == false ? side?.badges[title]?.lowercased() : nil
            let badgeWaiting = badge.map { $0.contains("await") || $0.contains("approval") || $0.contains("input") } ?? false
            let blocked = l?.status == "waiting" || l?.waitingFor != nil || badgeWaiting

            // Claude Desktop's verdict on the finished turn: it asked you something, got stuck, or failed.
            let openQuestion = ["blocked", "need_input", "failed"].contains(d.summaryCategory ?? "")
                || d.needsAction != nil
                || totals.openAsk != nil

            var state = SessionState.idle
            var prompt: String?
            if blocked {
                // An open question is a fact about the session, not news, so it shows even while you
                // are looking at that session. Only the banner notification is held back then.
                pending[d.sessionId] = nil
                state = .needsInput
                prompt = l?.waitingFor == "dialog open" ? "Approval needed" : nil
            } else if l?.status == "busy" {
                pending[d.sessionId] = nil
                state = .working
            } else if openQuestion {
                pending[d.sessionId] = nil
                state = .needsInput
                prompt = totals.openAsk ?? d.needsAction ?? (d.summaryCategory == "failed" ? "The last turn failed" : nil)
            } else if visible {
                pending[d.sessionId] = nil  // you are looking at it now
            } else {
                let wasActive = previous[d.sessionId] == .working || previous[d.sessionId] == .needsInput
                if primed, wasActive, pending[d.sessionId] == nil {
                    pending[d.sessionId] = now.timeIntervalSince1970
                }
                let unread = d.lastTurnEdge.map { $0.timeIntervalSince(d.lastFocused ?? .distantPast) > 1 } ?? false
                if pending[d.sessionId] != nil || unread {
                    // Finished without a recorded question. A closing "?" still earns orange.
                    state = totals.endsWithQuestion ? .needsInput : .needsYou
                }
            }
            prByRow[d.sessionId] = d.pr
            built.append(SessionRow(
                id: d.sessionId,
                title: title,
                project: (cwd as NSString).lastPathComponent,
                cwd: cwd,
                model: d.model.map(Format.model) ?? "",
                state: state,
                waitingFor: l?.waitingFor,
                lastActivity: activity,
                desktopId: d.sessionId,
                cliSessionId: cli,
                isLive: l != nil,
                tokens: totals))
            promptByRow[d.sessionId] = prompt
        }

        // Sessions running outside Claude Desktop (a terminal, an IDE).
        for l in live where !claimed.contains(l.sessionId) {
            let state: SessionState = l.status == "busy" ? .working
                : (l.status == "waiting" || l.waitingFor != nil) ? .needsInput : .idle
            built.append(SessionRow(
                id: l.sessionId,
                title: l.name?.nonEmpty ?? (l.cwd as NSString).lastPathComponent,
                project: (l.cwd as NSString).lastPathComponent,
                cwd: l.cwd,
                model: "",
                state: state,
                waitingFor: l.waitingFor,
                lastActivity: l.updated ?? now,
                desktopId: nil,
                cliSessionId: l.sessionId,
                isLive: true,
                tokens: tally.totals(forSession: l.sessionId)))
        }

        // Sessions you dismissed stay quiet until they finish another turn.
        let seen = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
        for i in built.indices where built[i].wantsYou {
            if let at = seen[built[i].id], built[i].lastActivity.timeIntervalSince1970 <= at + 1 {
                built[i].state = .idle
            }
        }

        built.sort { ($0.state, $1.lastActivity) < ($1.state, $0.lastActivity) }

        // Claude Desktop can briefly hold two records for one session; keep the first (most relevant).
        var seenIds = Set<String>()
        built = built.filter { seenIds.insert($0.id).inserted }

        let before = largeWindowModels.count
        for row in built where row.tokens.peakContext > 200_000 && !row.model.isEmpty {
            largeWindowModels.insert(row.model)
        }
        if largeWindowModels.count != before {
            UserDefaults.standard.set(Array(largeWindowModels), forKey: largeWindowKey)
        }
        for i in built.indices {
            built[i].contextWindow = window(for: built[i])
            built[i].git = git.info(for: built[i].cwd)
            built[i].pr = prByRow[built[i].id]
            built[i].prompt = promptByRow[built[i].id]
        }

        var finished: [SessionRow] = []
        if primed {
            // Anything that newly wants you: finished, stopped on a prompt, or a done turn that turned
            // out to be a question. Rows seen for the first time are not news.
            for row in built where row.wantsYou && row.id != onScreen {
                if let before = previous[row.id], before != row.state { finished.append(row) }
            }
        }
        // One follow-up per waiting spell. Spells already overdue at launch are marked as handled,
        // so starting the app never produces a burst of stale reminders.
        var overdue: [SessionRow] = []
        for row in built where remindAfter > 0 && row.wantsYou
            && now.timeIntervalSince(row.lastActivity) >= remindAfter
            && reminded[row.id] != row.lastActivity {
            reminded[row.id] = row.lastActivity
            if primed { overdue.append(row) }
        }
        let waitingIds = Set(built.filter { $0.wantsYou }.map(\.id))
        let liveIds = Set(built.map(\.id))
        pending = pending.filter { liveIds.contains($0.key) }
        UserDefaults.standard.set(pending, forKey: "pendingAttention")
        reminded = reminded.filter { waitingIds.contains($0.key) }

        previous = Dictionary(built.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        primed = true

        let plan = readPlan()
        DispatchQueue.main.async {
            if self.rows != built {
                self.rows = built
                // A plain record of what the panel is showing, for checking detection from outside.
                let names = ["needsInput", "done", "working", "idle"]
                UserDefaults.standard.set(
                    Dictionary(built.map { ($0.title, names[$0.state.rawValue]) }, uniquingKeysWith: { a, _ in a }),
                    forKey: "debugStates")
            }
            if self.plan != plan { self.plan = plan }
            finished.forEach { self.onFinished?($0) }
            overdue.forEach { self.onReminder?($0) }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
