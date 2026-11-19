import AppKit
import ApplicationServices
import Combine

struct ChatItem: Identifiable, Equatable, Codable {
    var title: String
    /// Whatever Claude shows beside the title, e.g. "Includes an artifact".
    var badge: String?
    var id: String { title }
}

/// The usage figure Claude Desktop shows in its usage ring, e.g. "77% of 5-hour limit".
struct LiveUsage: Equatable, Codable {
    var percent: Int
    /// Which limit this is, as Claude words it: "5-hour limit", "Weekly · all models", ...
    var limit: String
    /// When it resets, as Claude words it: "4:40 PM", "Sat 6:00 PM".
    var resets: String?
    var seenAt: Date

    /// "5h", "7d", or the limit's own name when it is neither.
    var shortLabel: String {
        let text = limit.lowercased()
        if text.contains("5-hour") || text.contains("5 hour") { return "5h" }
        if text.contains("week") { return "7d" }
        return limit
    }

    /// Parses the ring's accessibility label. Two shapes have been seen:
    ///   "Usage: 77% of 5-hour limit, Resets at 4:40 PM"
    ///   "Usage: Weekly · all models: 43%, Resets Sat 6:00 PM"
    static func parse(_ label: String, at date: Date) -> LiveUsage? {
        var text = label
        if let r = text.range(of: "Usage:") { text = String(text[r.upperBound...]) }
        guard let match = text.range(of: #"\d+%"#, options: .regularExpression),
              let percent = Int(text[match].dropLast()) else { return nil }
        var resets: String?
        var head = text
        if let r = text.range(of: "Resets", options: .caseInsensitive) {
            head = String(text[..<r.lowerBound])
            var when = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if when.lowercased().hasPrefix("at ") { when = String(when.dropFirst(3)) }
            resets = when.isEmpty ? nil : when
        }
        // What is left once the percentage and filler words are removed names the limit.
        var limit = head.replacingOccurrences(of: #"\d+%"#, with: "", options: .regularExpression)
        limit = limit.replacingOccurrences(of: " of ", with: " ")
        limit = limit.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
        return LiveUsage(percent: percent, limit: limit.isEmpty ? "limit" : limit, resets: resets, seenAt: date)
    }
}

/// A task from Claude Duet's Tasks pane.
struct DuetTask: Identifiable, Equatable, Codable {
    var title: String
    /// The group it sits under, as Duet words it: "Needs input", "Ready for review", ...
    var status: String
    var summary: String?
    var url: String?
    /// The channel or group it belongs to, by name. Nil for tasks in the main conversation.
    var space: String?
    var id: String { title }

    var needsInput: Bool { status.lowercased().contains("input") }
    var readyForReview: Bool { status.lowercased().contains("review") }
    /// Claude is on it right now; Duet shows a spinner beside these.
    var isWorking: Bool { status.lowercased().contains("working") }
}

/// A channel or group from Claude Duet's sidebar.
struct DuetSpace: Identifiable, Equatable, Codable {
    var name: String
    /// "channel" or "group", from how Duet labels the row.
    var kind: String
    var url: String?
    /// Duet marks it as having something you have not read.
    var unread: Bool?
    var id: String { url ?? "\(kind):\(name)" }

    var isGroup: Bool { kind == "group" }
    /// The last part of the address, e.g. "chan_01GH…", which task links and the page URL repeat.
    var key: String? { url.flatMap { URL(string: $0)?.lastPathComponent } }
}

/// Reads the "Recents" chat list out of Claude Desktop's sidebar through the Accessibility API.
///
/// Chats are stored on Anthropic's servers, so this is the only local view of them, and it has
/// a hard limit: the list exists in the window only while the sidebar's "Claude" tab is selected.
/// On the "Code" tab this keeps showing the last list it saw (`seenAt` says how old that is).
final class ChatReader: ObservableObject {
    @Published private(set) var chats: [ChatItem] = []
    @Published private(set) var seenAt: Date?
    @Published private(set) var trusted = AXIsProcessTrusted()

    /// Tasks from Claude Duet, as of the last time its page was open in the app (`duetSeenAt`).
    /// Like chats, Duet is only readable while it is on screen.
    @Published private(set) var duetTasks: [DuetTask] = []
    @Published private(set) var duetSeenAt: Date?
    /// Duet's channels and groups, as of the last time its sidebar was on screen.
    @Published private(set) var duetSpaces: [DuetSpace] = []
    private let duetSpacesKey = "duetSpaces"
    // The reader queue's own copies, so merging never reads the published values off the main thread.
    private var lastTasks: [DuetTask] = []
    /// When Duet's tasks were last read, and when the window was last sent to look. Reader queue only.
    private var lastDuetReadAt = Date.distantPast
    private var lastPeekAt = Date.distantPast
    private var lastSpaces: [DuetSpace] = []
    /// Claude's own live usage figure, read off the usage ring whenever a page that shows it is open.
    @Published private(set) var liveUsage: LiveUsage?
    private let usageKey = "liveUsage"
    private var tickCount = 0

    /// Called on the main queue when a Duet task is seen needing input for the first time.
    var onDuetNeedsInput: ((DuetTask) -> Void)?
    /// Titles already known to need input, so each task alerts once. Touched only on the reader queue.
    private var duetAlerted: Set<String>?
    private let duetKey = "duetTasks"
    private let duetSeenKey = "duetTasksSeenAt"

    /// What the sidebar looked like on the last pass, for the session reader (any thread).
    struct Sidebar {
        var at: Date
        var chatTab: Bool
        /// Row title -> the status text beside it, e.g. "Running" or "Awaiting input".
        var badges: [String: String]
    }

    private let sidebarLock = NSLock()
    private var lastSidebar: Sidebar?
    var sidebar: Sidebar? {
        sidebarLock.lock(); defer { sidebarLock.unlock() }
        return lastSidebar
    }

    private let queue = DispatchQueue(label: "claude-pulse.ax", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var preparedPid: pid_t = 0
    private let cacheKey = "chatCache"
    private let seenKey = "chatCacheSeenAt"
    /// Keep more than the panel shows, so hiding a chat lets the next one move up.
    private let limit = 30

    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([ChatItem].self, from: data) {
            chats = cached
            let t = UserDefaults.standard.double(forKey: seenKey)
            seenAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        if let data = UserDefaults.standard.data(forKey: usageKey) {
            liveUsage = try? JSONDecoder().decode(LiveUsage.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: duetKey),
           let cached = try? JSONDecoder().decode([DuetTask].self, from: data) {
            duetTasks = cached
            lastTasks = cached
            // Whatever already needed input when the widget last looked is not news after a restart.
            duetAlerted = Set(cached.filter { $0.needsInput }.map(\.title))
            let t = UserDefaults.standard.double(forKey: duetSeenKey)
            duetSeenAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
            if let duetSeenAt { lastDuetReadAt = duetSeenAt }
        }
        if let data = UserDefaults.standard.data(forKey: duetSpacesKey),
           let cached = try? JSONDecoder().decode([DuetSpace].self, from: data) {
            duetSpaces = cached
            lastSpaces = cached
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: .seconds(5), leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Shows the system prompt for Accessibility access.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Brings Claude forward and opens the chat, switching to the Claude tab first if needed.
    func open(_ chat: ChatItem) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first {
            app.activate()
        }
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot(), var scan = self.scanSidebar(root) else { return }
            if !scan.chatTab, let tab = scan.chatTabButton {
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                // Give the sidebar a moment to swap lists.
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 0.3)
                    if let again = self.scanSidebar(root), again.chatTab, again.buttons[chat.title] != nil {
                        scan = again
                        break
                    }
                }
            }
            if let button = scan.buttons[chat.title] {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
    }

    // MARK: - Reading

    private func tick() {
        let isTrusted = AXIsProcessTrusted()
        if isTrusted != trusted { DispatchQueue.main.async { self.trusted = isTrusted } }
        guard isTrusted, let root = claudeRoot() else { return }
        if Settings.bool(Settings.Key.showDuet, default: true) {
            readDuet(root)
            peekAtDuetIfDue(root)
        }
        // The ring sits deep in the page, so finding it is the costliest read here: every third pass.
        tickCount += 1
        if tickCount % 3 == 1, Settings.bool(Settings.Key.showUsage, default: true) { readUsage(root) }
        guard let scan = scanSidebar(root) else { return }

        var badges: [String: String] = [:]
        for row in scan.rows { if let badge = row.badge { badges[row.title] = badge } }
        sidebarLock.lock()
        lastSidebar = Sidebar(at: Date(), chatTab: scan.chatTab, badges: badges)
        sidebarLock.unlock()

        guard scan.chatTab, Settings.bool(Settings.Key.showChats, default: true) else { return }

        let items = Array(scan.recents.prefix(limit))
        guard !items.isEmpty else { return }
        let now = Date()
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: seenKey)
        }
        DispatchQueue.main.async {
            if self.chats != items { self.chats = items }
            self.seenAt = now
        }
    }

    // MARK: - Usage

    private func readUsage(_ root: AXUIElement) {
        for window in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            guard let ring = find(in: window, budget: 4_000, maxDepth: 70, where: { e in
                self.attr(e, kAXRoleAttribute) as? String == "AXPopUpButton" && self.label(e).hasPrefix("Usage")
            }), let usage = LiveUsage.parse(label(ring), at: Date()) else { continue }
            if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: usageKey) }
            DispatchQueue.main.async { self.liveUsage = usage }
            return
        }
    }

    // MARK: - Duet

    /// Duet is the page at claude.ai/messages. When it is showing, read its channels and groups,
    /// then the Active tab of its Tasks pane.
    ///
    /// The Tasks pane follows the conversation on screen: "Everything" lists every task, while a
    /// channel or group lists only its own ("Tasks in #name"). So a reading taken inside a channel
    /// replaces that channel's tasks and leaves the rest as they were last seen.
    private func readDuet(_ root: AXUIElement, trace: ((String) -> Void)? = nil, peeking: Bool = false) {
        guard let page = duetPage(root) else { trace?("Duet is not on screen"); return }
        // Nil means the sidebar is hidden, which says nothing about what exists.
        let freshSpaces = readDuetSpaces(page)
        if let freshSpaces, freshSpaces != lastSpaces {
            lastSpaces = freshSpaces
            if let data = try? JSONEncoder().encode(freshSpaces) {
                UserDefaults.standard.set(data, forKey: duetSpacesKey)
            }
            DispatchQueue.main.async { self.duetSpaces = freshSpaces }
        }
        let spaces = lastSpaces

        // The pane can be hidden; the conversation's own task cards are still worth reading then.
        let pane = find(in: page, budget: 1_500, where: { e in
            self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
        })

        // Which conversation is showing: its key is the last part of the page address.
        let pageKey = (attr(page, kAXURLAttribute) as? URL).flatMap { url -> String? in
            let last = url.lastPathComponent
            return last == "messages" || last.isEmpty ? nil : last
        }

        var group = ""
        var activeTab = true
        var sawTabs = false
        var emptyState = false
        var paneSpace: String?
        var tasks: [DuetTask] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int, _ region: String?) {
            visited += 1
            guard visited < 1_200, depth < 40 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            var region = region
            // "Everything" files each channel's tasks in a region of its own:
            // "Tasks in the performance-review channel".
            if depth > 0, attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" {
                let text = label(e)
                for suffix in [" channel", " group"] where text.hasPrefix("Tasks in the ") && text.hasSuffix(suffix) {
                    region = String(text.dropFirst("Tasks in the ".count).dropLast(suffix.count))
                }
            }
            switch role {
            case "AXRadioButton":
                // Tabs: Active, Up next, Scheduled, Resolved. Only the Active list is kept.
                sawTabs = true
                if (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1 {
                    activeTab = label(e) == "Active" || staticTexts(in: e, depth: 0).first == "Active"
                }
            case "AXHeading":
                let text = label(e)
                if text.hasPrefix("Tasks in #") {
                    paneSpace = String(text.dropFirst("Tasks in #".count))
                } else if text == "Nothing on your list yet" {
                    // A channel with no tasks at all has no tabs, only this.
                    emptyState = true
                } else {
                    // "Ready for review 3 tasks" -> "Ready for review"
                    group = text.replacingOccurrences(of: #"\s+\d+\s+tasks?$"#, with: "", options: .regularExpression)
                }
            case "AXLink":
                guard let title = staticTexts(in: e, depth: 0).first else { break }
                // The link's own label reads "Title, Status, summary". The status is taken from
                // there, because the heading above is a status in one view and a channel in another.
                var summary: String?
                let full = label(e)
                trace?("listed link under [\(group)] in [\(region ?? "-")]: \(full.prefix(120))")
                // The heading above is a status in a channel's own list but the channel's name in
                // "Everything", and the label puts the status before or after the title. So prefer
                // a status Duet is known to use, wherever it sits in the label.
                var status = full.components(separatedBy: ", ").first(where: Self.isDuetStatus) ?? ""
                if !status.isEmpty {
                    let lead = "\(title), \(status), "
                    if full.hasPrefix(lead) { summary = String(full.dropFirst(lead.count)) }
                } else if full.hasPrefix(title + ", ") {
                    let rest = full.dropFirst(title.count + 2)
                    if let comma = rest.range(of: ", ") {
                        if rest[..<comma.lowerBound].count <= 40 {
                            status = String(rest[..<comma.lowerBound])
                            summary = String(rest[comma.upperBound...])
                        }
                    } else if rest.count <= 40 {
                        status = String(rest)
                    }
                }
                if status.isEmpty { status = region == nil ? group : "Active" }
                guard !status.isEmpty else { break }
                let url = (attr(e, kAXURLAttribute) as? URL)?.absoluteString
                // In "Everything" a task may still say where it lives, in its address or its label.
                let home = region ?? spaces.first { space in
                    if let key = space.key, let url, url.contains(key) { return true }
                    return full.contains("#\(space.name)")
                }?.name
                if !tasks.contains(where: { $0.title == title }) {
                    tasks.append(DuetTask(title: title, status: status, summary: summary?.isEmpty == false ? summary : nil,
                                          url: url, space: home))
                }
                return  // nothing useful below a task link
            default:
                break
            }
            for child in children(e) { walk(child, depth + 1, region) }
        }
        if let pane { walk(pane, 0, nil) }
        trace?("pane: \(pane != nil), page key: \(pageKey ?? "-"), tabs: \(sawTabs), active tab: \(activeTab), empty: \(emptyState), listed: \(tasks.count)")

        var current: String?
        if let pageKey {
            current = spaces.first { $0.key == pageKey }?.name ?? paneSpace
            // Inside a conversation that cannot be named: nothing here can be filed correctly.
            guard current != nil else { return }
        }
        // With a task's detail open, the pane shows that task instead of the list and has no tabs.
        // That is not an empty list, so the remembered tasks stay. What can still be read then is
        // the status Duet prints on each task's card in the conversation and on the open task,
        // which is how a task that starts needing input is noticed while its detail is open.
        let listReadable = pane != nil && ((sawTabs && activeTab) || (current != nil && emptyState))
        if !listReadable {
            let cards = duetCards(page: page, pane: pane, spaces: spaces, current: current, trace: trace)
            trace?("list not readable; cards: " + cards.map { "\($0.title.prefix(30)) = \($0.status)" }.joined(separator: "; "))
            guard !cards.isEmpty else { return }
            tasks = lastTasks
            for card in cards {
                let status = card.status.lowercased()
                let finished = ["done", "resolved", "complete", "cancel", "dismiss"].contains { status.contains($0) }
                let live = status.contains("working") || status.contains("input") || status.contains("review")
                if let i = tasks.firstIndex(where: { $0.title == card.title }) {
                    if finished {
                        tasks.remove(at: i)
                    } else if live {
                        tasks[i].status = card.status
                        if let summary = card.summary { tasks[i].summary = summary }
                        if tasks[i].space == nil { tasks[i].space = card.space }
                    }
                } else if live {
                    tasks.append(card)
                }
            }
        } else if let current {
            let titles = Set(tasks.map(\.title))
            for i in tasks.indices { tasks[i].space = current }
            tasks = lastTasks.filter { $0.space != current && !titles.contains($0.title) } + tasks
        } else {
            // Keep what an earlier look inside a channel established, where this list does not say.
            let known = Dictionary(lastTasks.compactMap { task in task.space.map { (task.title, $0) } },
                                   uniquingKeysWith: { first, _ in first })
            for i in tasks.indices where tasks[i].space == nil { tasks[i].space = known[tasks[i].title] }
        }
        // A channel or group that has been deleted no longer holds anything.
        if freshSpaces != nil {
            let names = Set(spaces.map(\.name))
            for i in tasks.indices {
                if let space = tasks[i].space, space != current, !names.contains(space) { tasks[i].space = nil }
            }
        }

        tasks.sort { ($0.needsInput ? 0 : $0.readyForReview ? 1 : 2) < ($1.needsInput ? 0 : $1.readyForReview ? 1 : 2) }
        lastTasks = tasks

        // Alert once per task when it starts needing input. The very first list ever read only
        // sets the baseline. Nothing fires while Claude is the front app: you can see Duet then.
        let waiting = Set(tasks.filter { $0.needsInput }.map(\.title))
        var fresh: [DuetTask] = []
        if let alerted = duetAlerted {
            // A background look is over in a moment, so what it finds is news even with Claude in front.
            let claudeIsFront = !peeking && DispatchQueue.main.sync {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
            }
            if !claudeIsFront {
                fresh = tasks.filter { $0.needsInput && !alerted.contains($0.title) }
                duetAlerted = waiting
            } else {
                // Seen on screen: count them as known, and forget ones that stopped waiting.
                duetAlerted = waiting
            }
        } else {
            duetAlerted = waiting
        }
        let now = Date()
        lastDuetReadAt = now
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: duetKey)
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: duetSeenKey)
        }
        DispatchQueue.main.async {
            if self.duetTasks != tasks { self.duetTasks = tasks }
            self.duetSeenAt = now
            fresh.forEach { self.onDuetNeedsInput?($0) }
        }
    }

    /// Diagnostic: Duet's channel and group list, and what the Tasks pane shows in each of them.
    /// Visits every channel and group, then puts the window back where it was.
    func debugDuetSpaces(trace: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot() else { trace("no Claude window"); return }
            let wasOnDuet = self.duetPage(root) != nil
            let wasOnCode = self.scanSidebar(root).map { !$0.chatTab } ?? false
            if !wasOnDuet { self.navigateToDuet(root, trace: trace) }
            var page: AXUIElement?
            for _ in 0..<20 where page == nil {
                Thread.sleep(forTimeInterval: 0.4)
                page = self.duetPage(root)
            }
            guard let page else { trace("Duet did not open"); return }

            func dump(_ e: AXUIElement, _ depth: Int, _ left: inout Int) {
                left -= 1
                guard left > 0, depth < 40 else { return }
                let role = self.attr(e, kAXRoleAttribute) as? String ?? "?"
                let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .map { (self.attr(e, $0) as? String) ?? (self.attr(e, $0) as? NSNumber)?.stringValue ?? "" }
                let url = (self.attr(e, kAXURLAttribute) as? URL)?.absoluteString ?? ""
                let sub = self.attr(e, kAXSubroleAttribute) as? String ?? ""
                if role != "AXGroup" || !sub.isEmpty || texts.contains(where: { !$0.isEmpty }) {
                    trace(String(repeating: " ", count: depth) + "\(role) \(sub) t=[\(texts[0].prefix(90))] d=[\(texts[1].prefix(90))] v=[\(texts[2].prefix(90))] \(url)")
                }
                for child in self.children(e) { dump(child, depth + 1, &left) }
            }
            func nav() -> AXUIElement? {
                self.find(in: page, budget: 400, where: { e in
                    self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkNavigation"
                })
            }
            func dumpTasks(_ name: String) {
                Thread.sleep(forTimeInterval: 1.6)
                let here = self.duetPage(root)
                trace("== \(name): page url \((here.flatMap { self.attr($0, kAXURLAttribute) as? URL })?.absoluteString ?? "-")")
                guard let here else { return }
                var pane = self.find(in: here, budget: 2_500, where: { e in
                    self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
                })
                if pane == nil, let button = self.find(in: here, budget: 400, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e).hasPrefix("Tasks")
                }) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 1.0)
                    pane = self.find(in: here, budget: 2_500, where: { e in
                        self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
                    })
                }
                guard let pane else { trace("no Tasks pane"); return }
                if let active = self.find(in: pane, budget: 200, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXRadioButton" && self.staticTexts(in: e, depth: 0).first ?? self.label(e) == "Active"
                }) {
                    AXUIElementPerformAction(active, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.8)
                }
                var left = 500
                dump(pane, 0, &left)
            }

            trace("== navigation")
            if let nav = nav() { var left = 300; dump(nav, 0, &left) } else { trace("no navigation landmark") }

            var links: [(String, AXUIElement)] = []
            func collect(_ e: AXUIElement, _ depth: Int) {
                guard depth < 12 else { return }
                if self.attr(e, kAXRoleAttribute) as? String == "AXLink",
                   let url = (self.attr(e, kAXURLAttribute) as? URL)?.absoluteString,
                   url.contains("/messages/") {
                    links.append((self.label(e), e))
                    return
                }
                for child in self.children(e) { collect(child, depth + 1) }
            }
            if let nav = nav() { collect(nav, 0) }
            dumpTasks("as found")
            for (name, link) in links {
                AXUIElementPerformAction(link, kAXPressAction as CFString)
                dumpTasks(name)
            }
            if let nav = nav(), let everything = self.find(in: nav, budget: 200, where: { e in
                self.attr(e, kAXRoleAttribute) as? String == "AXLink" && self.staticTexts(in: e, depth: 0).first == "Everything"
            }) {
                AXUIElementPerformAction(everything, kAXPressAction as CFString)
                dumpTasks("Everything")
            }
            if !wasOnDuet, wasOnCode, let url = URL(string: "claude://code/continue?session=last") {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                trace("returned to the last Code session")
            }
            trace("done")
        }
    }

    /// Duet can only be read while it is on screen, so a task that starts needing input while you
    /// are in a Code session would go unnoticed. While a task is known to be running, this sends
    /// Claude's window to Duet for a moment every few minutes, reads the list, and puts it back.
    ///
    /// It only does so from a Code session, which can be returned to exactly, and never while you
    /// are using Claude: the window would change under your hands and your typing would land in Duet.
    private func peekAtDuetIfDue(_ root: AXUIElement, trace: ((String) -> Void)? = nil, force: Bool = false) {
        let minutes = Settings.int(Settings.Key.duetPeekMinutes, default: 5)
        guard force || minutes > 0 else { return }
        let interval = TimeInterval(max(1, minutes) * 60)
        let now = Date()
        if !force {
            guard lastTasks.contains(where: \.isWorking),
                  now.timeIntervalSince(lastDuetReadAt) >= interval,
                  now.timeIntervalSince(lastPeekAt) >= interval else { return }
        }
        guard duetPage(root) == nil else { return }
        guard let scan = scanSidebar(root), !scan.chatTab else { trace?("not on a Code session; leaving the window alone"); return }
        let claudeIsFront = DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
        }
        if claudeIsFront, let anyInput = CGEventType(rawValue: ~0) {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            guard idle >= 20 else { trace?("you are using Claude; not now"); return }
        }
        lastPeekAt = now
        trace?("looking in on Duet")

        navigateToDuet(root, trace: trace)
        showDuetSpace(nil, root: root, trace: trace)
        if let page = duetPage(root) {
            // The page fills in over a second or two. Wait for the Tasks list and its tabs, bringing
            // the pane back if it is hidden and stepping out of a task whose detail was left open.
            var revealed = false
            var steppedBack = false
            var ready = false
            for _ in 0..<16 where !ready {
                Thread.sleep(forTimeInterval: 0.4)
                guard let pane = find(in: page, budget: 2_500, where: { e in
                    self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
                }) else {
                    if !revealed, let button = find(in: page, budget: 400, where: { e in
                        self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e).hasPrefix("Tasks")
                    }) {
                        revealed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    }
                    continue
                }
                if let active = find(in: pane, budget: 300, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXRadioButton"
                        && (self.staticTexts(in: e, depth: 0).first ?? self.label(e)) == "Active"
                }) {
                    // Duet opens on "Up next" when nothing is active; the Active tab is the one that is read.
                    if (attr(active, kAXValueAttribute) as? NSNumber)?.intValue != 1 {
                        AXUIElementPerformAction(active, kAXPressAction as CFString)
                        Thread.sleep(forTimeInterval: 0.7)
                    }
                    ready = true
                } else if !steppedBack, let back = find(in: pane, budget: 300, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e) == "Back"
                }) {
                    steppedBack = AXUIElementPerformAction(back, kAXPressAction as CFString) == .success
                    trace?("left the open task to reach the list")
                }
            }
            trace?("task list ready: \(ready)")
            readDuet(root, trace: trace, peeking: true)
        } else {
            trace?("Duet did not open")
        }

        // Back to the Code session, without bringing Claude in front of whatever you are doing.
        if let url = URL(string: "claude://code/continue?session=last") {
            DispatchQueue.main.async {
                let quiet = NSWorkspace.OpenConfiguration()
                quiet.activates = false
                NSWorkspace.shared.open(url, configuration: quiet)
            }
            trace?("returned to the last Code session")
        }
    }

    /// Diagnostic: one background look at Duet right now, whatever the timer says.
    func debugDuetPeek(trace: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot() else { trace("no Claude window"); return }
            self.peekAtDuetIfDue(root, trace: trace, force: true)
            trace("tasks now: " + self.lastTasks.map { "\($0.title.prefix(30)) = \($0.status) in \($0.space ?? "main")" }.joined(separator: "; "))
        }
    }

    /// Diagnostic: one pass of the Duet reader, saying what it found.
    func debugDuetRead(trace: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot() else { trace("no Claude window"); return }
            self.readDuet(root, trace: trace)
            trace("tasks now: " + self.lastTasks.map { "\($0.title.prefix(30)) = \($0.status) in \($0.space ?? "main")" }.joined(separator: "; "))
        }
    }

    /// The statuses Duet is known to give a task.
    private static func isDuetStatus(_ text: String) -> Bool {
        ["working", "needs input", "ready for review", "done", "resolved", "completed", "cancelled"]
            .contains(text.lowercased())
    }

    /// Task statuses readable without the Tasks list: the cards Duet posts in the conversation
    /// ("Title · Needs input"), and the header of a task whose detail is open ("Working. …").
    /// Later entries win, and the open task's header is last.
    private func duetCards(page: AXUIElement, pane: AXUIElement?, spaces: [DuetSpace], current: String?,
                           trace: ((String) -> Void)? = nil) -> [DuetTask] {
        var cards: [DuetTask] = []
        func add(_ card: DuetTask) {
            cards.removeAll { $0.title == card.title }
            cards.append(card)
        }
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 3_000, depth < 50 else { return }
            if attr(e, kAXRoleAttribute) as? String == "AXLink",
               let url = (attr(e, kAXURLAttribute) as? URL)?.absoluteString, url.contains("task=") {
                // The link's label reads "Title, Status" or "Title, Status, summary", whatever the
                // card happens to draw. Some cards also spell it out as "Title · Status".
                let texts = staticTexts(in: e, depth: 0).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let full = label(e)
                trace?("task link: \(full.prefix(110))")
                // Cards word it several ways: "Title, Working, summary", "Title, Added, Ready for
                // review", "Ready for review, Title". So look for a status Duet is known to use,
                // wherever it sits, and take the title from the text that is not one.
                let isStatus = Self.isDuetStatus
                let parts = full.components(separatedBy: ", ")
                guard let title = texts.first(where: { !isStatus($0) && $0 != "·" && $0 != "Added" }) else { return }
                let status = parts.first(where: isStatus) ?? texts.first(where: isStatus)
                var summary: String?
                if let status, full.hasPrefix("\(title), \(status), ") {
                    summary = String(full.dropFirst("\(title), \(status), ".count))
                }
                if let status, !status.isEmpty, status.count <= 40 {
                    let home = spaces.first { space in space.key.map { url.contains($0) } ?? false }?.name ?? current
                    add(DuetTask(title: title, status: status, summary: summary?.isEmpty == false ? summary : nil,
                                 url: url, space: home))
                }
                return
            }
            for child in children(e) { walk(child, depth + 1) }
        }
        walk(page, 0)
        trace?("card scan visited \(visited) elements")

        if let pane, let header = find(in: pane, budget: 200, where: { e in
            self.attr(e, kAXSubroleAttribute) as? String == "AXSectionHeader"
        }), find(in: header, budget: 20, where: { e in
            self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e) == "Back"
        }) != nil {
            // The header holds the Back button (with the title in it), then the status, either as
            // text ("Working. Find the values.") or as a button ("Ready for review. 1 update").
            let title = staticTexts(in: header, depth: 0).first
            let line = children(header).map { label($0) }.first { text in
                !text.isEmpty && text != "Back" && text != title && !text.hasPrefix("More for") && !text.hasPrefix("Hide")
            }
            trace?("open task header: \(title ?? "-") / \(line ?? "-")")
            if let title, let line {
                let parts = line.components(separatedBy: ". ")
                let status = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if !status.isEmpty, status.count <= 40 {
                    // The rest is a summary only while Claude is working; otherwise it is a count of updates.
                    let summary = parts.count > 1 && status.lowercased().contains("working")
                        ? parts.dropFirst().joined(separator: ". ") : nil
                    add(DuetTask(title: title, status: status, summary: summary, url: nil, space: current))
                }
            }
        }
        return cards
    }

    /// The channels and groups in Duet's sidebar, or nil when the sidebar is not on screen.
    ///
    /// Each one is a link to `claude.ai/messages/<key>` whose label ends in what it is:
    /// "return-migration channel". Lists are labelled too ("Channels"), as a second opinion.
    private func readDuetSpaces(_ page: AXUIElement) -> [DuetSpace]? {
        guard let nav = duetNavigation(page) else { return nil }
        var spaces: [DuetSpace] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int, _ list: String) {
            visited += 1
            guard visited < 600, depth < 20 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            var list = list
            if role == "AXList" {
                list = label(e).lowercased()
            } else if role == "AXLink" {
                guard let url = attr(e, kAXURLAttribute) as? URL,
                      url.lastPathComponent != "messages", url.path.hasPrefix("/messages/"),
                      let name = staticTexts(in: e, depth: 0).first ?? Optional(label(e)), !name.isEmpty
                else { return }
                // "return-migration channel", or "return-migration channel, unread".
                let full = label(e).lowercased()
                let lowered = name.lowercased()
                let kind = full.hasPrefix(lowered + " group") || (!full.hasPrefix(lowered + " channel") && list.contains("group"))
                    ? "group" : "channel"
                if !spaces.contains(where: { $0.name == name }) {
                    spaces.append(DuetSpace(name: name, kind: kind, url: url.absoluteString,
                                            unread: full.hasSuffix(", unread") ? true : nil))
                }
                return
            }
            for child in children(e) { walk(child, depth + 1, list) }
        }
        walk(nav, 0, "")
        return spaces
    }

    private func duetNavigation(_ page: AXUIElement) -> AXUIElement? {
        find(in: page, budget: 400, where: { e in
            self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkNavigation"
        })
    }

    /// Waits for Duet to be on screen, then shows the named channel or group, or "Everything"
    /// for nil. The Tasks pane only lists a task while its own conversation or Everything is showing.
    private func showDuetSpace(_ name: String?, root: AXUIElement, trace: ((String) -> Void)? = nil) {
        var page: AXUIElement?
        for _ in 0..<12 where page == nil {
            page = duetPage(root)
            if page == nil { Thread.sleep(forTimeInterval: 0.35) }
        }
        guard let page, let nav = duetNavigation(page) else { return }
        let wanted = name ?? "Everything"
        guard let link = find(in: nav, budget: 400, where: { e in
            self.attr(e, kAXRoleAttribute) as? String == "AXLink" && self.staticTexts(in: e, depth: 0).first == wanted
        }) else { trace?("no sidebar entry for \(wanted)"); return }
        func bare(_ e: AXUIElement) -> String? {
            (attr(e, kAXURLAttribute) as? URL)?.absoluteString.components(separatedBy: "?").first
        }
        if let here = bare(page), here == bare(link) { return }
        AXUIElementPerformAction(link, kAXPressAction as CFString)
        trace?("showed \(wanted)")
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Brings Claude forward on a channel or group.
    func openDuetSpace(_ space: DuetSpace) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first {
            app.activate()
        }
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot() else { return }
            if self.duetPage(root) == nil { self.navigateToDuet(root, trace: nil) }
            self.showDuetSpace(space.name, root: root)
        }
    }

    /// Gets Claude's window onto Duet by pressing the Claude tab and then the Claude Duet button.
    private func navigateToDuet(_ root: AXUIElement, trace: ((String) -> Void)?) {
        if let scan = scanSidebar(root), !scan.chatTab, let tab = scan.chatTabButton {
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
            trace?("pressed the Claude tab")
            Thread.sleep(forTimeInterval: 0.6)
        }
        var pressed = false
        for _ in 0..<12 where !pressed {
            var budget = 600
            if let sidebar = findSidebar(root, depth: 0, budget: &budget),
               let button = find(in: sidebar, budget: 500, where: { e in
                   self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e).hasPrefix("Claude Duet")
               }) {
                pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            } else {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        trace?("pressed the Claude Duet button: \(pressed)")
    }

    /// Ticks the task's checkbox in Duet's Tasks pane, which marks it complete there.
    ///
    /// Duet has to be on screen for this, so if Claude's window was somewhere else it is taken to
    /// Duet, the box is ticked, and the window is put back where it was. With `dryRun` everything
    /// happens except the tick itself.
    func completeDuet(_ task: DuetTask, dryRun: Bool = false, trace: ((String) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot() else { trace?("no Claude window"); return }
            let wasOnDuet = self.duetPage(root) != nil
            // Sidebar present and not on the Claude tab means a Code session was showing.
            let wasOnCode = self.scanSidebar(root).map { !$0.chatTab } ?? false
            trace?("was on Duet: \(wasOnDuet), was on Code: \(wasOnCode)")
            if !wasOnDuet { self.navigateToDuet(root, trace: trace) }
            self.showDuetSpace(task.space, root: root, trace: trace)

            var done = false
            var revealedPane = false
            for attempt in 0..<30 where !done {
                Thread.sleep(forTimeInterval: 0.35)
                guard let page = self.duetPage(root) else { continue }
                guard let pane = self.find(in: page, budget: 2_500, where: { e in
                    self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
                }) else {
                    // The pane is hidden: its header button brings it back.
                    if !revealedPane, attempt >= 4, let button = self.find(in: page, budget: 400, where: { e in
                        self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e).hasPrefix("Tasks")
                    }) {
                        revealedPane = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                        trace?("showed the Tasks pane: \(revealedPane)")
                    }
                    continue
                }
                if let box = self.find(in: pane, budget: 1_500, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXCheckBox" && self.label(e) == task.title
                }) {
                    if dryRun {
                        trace?("found the task's checkbox (dry run, not ticked)")
                    } else {
                        let result = AXUIElementPerformAction(box, kAXPressAction as CFString)
                        trace?("ticked the checkbox: \(result.rawValue)")
                        guard result == .success else { break }
                    }
                    done = true
                } else if let more = self.find(in: pane, budget: 1_500, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXPopUpButton" && self.label(e) == "More for \(task.title)"
                }) {
                    // Duet only draws a task's tick box under the mouse, so use its "More" menu instead.
                    AXUIElementPerformAction(more, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.7)
                    var items: [(String, AXUIElement)] = []
                    var seen = 0
                    func collect(_ e: AXUIElement, _ depth: Int) {
                        seen += 1
                        guard seen < 5_000, depth < 60 else { return }
                        let role = self.attr(e, kAXRoleAttribute) as? String ?? ""
                        if role == "AXMenuItem" || role == "AXMenuItemCheckbox" || role == "AXMenuItemRadio" {
                            items.append((self.label(e), e))
                            return
                        }
                        for child in self.children(e) { collect(child, depth + 1) }
                    }
                    for window in (self.attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { collect(window, 0) }
                    trace?("menu items: \(items.map(\.0))")
                    let choice = items.first { item in
                        let text = item.0.lowercased()
                        return text.contains("complete") || text.contains("resolve") || text.contains("done")
                    }
                    if let choice, !dryRun {
                        let result = AXUIElementPerformAction(choice.1, kAXPressAction as CFString)
                        trace?("chose '\(choice.0)': \(result.rawValue)")
                        done = result == .success
                    } else {
                        trace?(choice == nil ? "no complete option in the menu" : "would choose '\(choice!.0)' (dry run)")
                        // Close the menu again without choosing anything.
                        AXUIElementPerformAction(more, kAXPressAction as CFString)
                        if let menu = items.first?.1 { AXUIElementPerformAction(menu, "AXCancel" as CFString) }
                        done = choice != nil
                    }
                    if choice == nil { break }
                } else if let back = self.find(in: pane, budget: 200, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e) == "Back"
                }) {
                    // A task's detail is open in the pane; step back to the list.
                    AXUIElementPerformAction(back, kAXPressAction as CFString)
                    trace?("left the task detail to reach the list")
                }
            }
            if !done { trace?("could not find the task's checkbox") }

            if done, !dryRun {
                self.lastTasks.removeAll { $0.title == task.title }
                DispatchQueue.main.async {
                    self.duetTasks.removeAll { $0.title == task.title }
                    if let data = try? JSONEncoder().encode(self.duetTasks) {
                        UserDefaults.standard.set(data, forKey: self.duetKey)
                    }
                }
            }
            // Put the window back where it was.
            if !wasOnDuet {
                Thread.sleep(forTimeInterval: 0.6)
                if wasOnCode, let url = URL(string: "claude://code/continue?session=last") {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    trace?("returned to the last Code session")
                } else if let page = self.duetPage(root), let back = self.find(in: page, budget: 80, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e) == "Back to Claude"
                }) {
                    AXUIElementPerformAction(back, kAXPressAction as CFString)
                    trace?("returned to Claude")
                }
            }
        }
    }

    /// Brings Claude forward, opens Duet if it is not already showing, and clicks the task there.
    ///
    /// There is no link that does this: the app's `claude://` handler does not route to Duet
    /// (`claude://claude.ai/messages` is ignored). So this presses what a person would press:
    /// the sidebar's Claude tab, its "Claude Duet" button, then the task in Duet's Tasks pane.
    /// Pass nil to just open Duet.
    func openDuet(_ task: DuetTask?, trace: ((String) -> Void)? = nil) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first {
            app.activate()
        }
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot() else { trace?("no Claude window"); return }
            let alreadyOpen = self.duetPage(root) != nil
            trace?("duet already open: \(alreadyOpen)")
            if !alreadyOpen { self.navigateToDuet(root, trace: trace) }
            guard let task else { return }
            self.showDuetSpace(task.space, root: root, trace: trace)
            // First choice: Duet's own "Show in main channel", from the task's More menu. Duet knows
            // which message the task belongs to, so nothing has to be searched for.
            if self.showInMainChannel(task, root: root, trace: trace) { return }
            trace?("falling back to searching the conversation")
            // Fallback. Two ways to land on the task, tried together until one works:
            //  - scroll the conversation to the latest message that mentions it (what you came for);
            //  - press it in the Tasks pane, which opens the task's own thread beside the conversation.
            // The Tasks pane can be hidden, so it is optional; if the conversation has no mention
            // loaded either, the pane is opened as a last resort.
            var pressedTask = false
            var revealedPane = false
            for attempt in 0..<34 {
                guard let page = self.duetPage(root) else {
                    Thread.sleep(forTimeInterval: 0.35)
                    continue
                }
                let pane = self.find(in: page, budget: 2_500, where: { e in
                    self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
                })
                if !pressedTask, let pane, let link = self.find(in: pane, budget: 1_200, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXLink"
                        && self.staticTexts(in: e, depth: 0).first == task.title
                }) {
                    pressedTask = AXUIElementPerformAction(link, kAXPressAction as CFString) == .success
                    trace?("try \(attempt): opened the task in the Tasks pane: \(pressedTask)")
                    Thread.sleep(forTimeInterval: 0.9)
                }
                if self.scrollDiscussion(to: task, in: page, trace: trace) { return }
                // Not in the stretch Duet has loaded: once the page has settled, go looking further back.
                if attempt >= 6 {
                    let found = self.scrollDiscussion(to: task, in: page, loadEarlier: true, trace: trace)
                    if found || pressedTask { return }
                }
                if !revealedPane, pane == nil, attempt >= 10,
                   let button = self.find(in: page, budget: 400, where: { e in
                       self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e).hasPrefix("Tasks")
                   }) {
                    revealedPane = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    trace?("try \(attempt): showed the Tasks pane: \(revealedPane)")
                }
                Thread.sleep(forTimeInterval: 0.35)
            }
            trace?("gave up")
        }
    }

    /// Diagnostic: tries "Show in main channel" on the first task under Duet's Resolved tab, which
    /// changes nothing in Duet, then puts the Tasks pane back on Active.
    func debugShowInMainChannel(trace: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self, let root = self.claudeRoot() else { trace("no Claude window"); return }
            if self.duetPage(root) == nil { self.navigateToDuet(root, trace: trace) }
            func pane() -> AXUIElement? {
                guard let page = self.duetPage(root) else { return nil }
                return self.find(in: page, budget: 2_500, where: { e in
                    self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
                })
            }
            func tab(_ name: String) -> AXUIElement? {
                pane().flatMap { self.find(in: $0, budget: 300, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXRadioButton"
                        && (self.label(e) == name || self.staticTexts(in: e, depth: 0).first == name)
                }) }
            }
            var title: String?
            for _ in 0..<20 where title == nil {
                Thread.sleep(forTimeInterval: 0.4)
                guard let resolved = tab("Resolved") else { continue }
                AXUIElementPerformAction(resolved, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.8)
                if let p = pane(), let more = self.find(in: p, budget: 1_500, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXPopUpButton" && self.label(e).hasPrefix("More for ")
                }) {
                    title = String(self.label(more).dropFirst("More for ".count))
                }
            }
            guard let title else { trace("no resolved task found to test with"); return }
            trace("testing with a resolved task (title length \(title.count))")
            let task = DuetTask(title: title, status: "Resolved", summary: nil, url: nil)
            let ok = self.showInMainChannel(task, root: root, trace: trace)
            Thread.sleep(forTimeInterval: 1.2)
            if let page = self.duetPage(root) {
                let found = self.scrollDiscussion(to: task, in: page, trace: nil)
                trace("show in main channel pressed: \(ok); a message mentioning the task is loaded afterwards: \(found)")
            }
            if let active = tab("Active") { AXUIElementPerformAction(active, kAXPressAction as CFString); trace("Tasks pane back on Active") }
        }
    }

    /// Opens the task's "More" menu in the Tasks pane and chooses "Show in main channel".
    /// Returns false if the pane, the task or that menu item cannot be found, leaving any menu closed.
    private func showInMainChannel(_ task: DuetTask, root: AXUIElement, trace: ((String) -> Void)?) -> Bool {
        var revealedPane = false
        for attempt in 0..<22 {
            Thread.sleep(forTimeInterval: 0.35)
            guard let page = duetPage(root) else { continue }
            guard let pane = find(in: page, budget: 2_500, where: { e in
                self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
            }) else {
                if !revealedPane, attempt >= 4, let button = find(in: page, budget: 400, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e).hasPrefix("Tasks")
                }) {
                    revealedPane = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    trace?("showed the Tasks pane: \(revealedPane)")
                }
                continue
            }
            guard let more = find(in: pane, budget: 1_500, where: { e in
                self.attr(e, kAXRoleAttribute) as? String == "AXPopUpButton" && self.label(e) == "More for \(task.title)"
            }) else {
                // Another task's detail may be filling the pane; step back to the list.
                if let back = find(in: pane, budget: 200, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e) == "Back"
                }) {
                    AXUIElementPerformAction(back, kAXPressAction as CFString)
                    trace?("left a task detail to reach the list")
                }
                continue
            }
            AXUIElementPerformAction(more, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.7)
            let items = menuItems(root)
            if let item = items.first(where: { $0.0.lowercased().contains("main channel") }) {
                let result = AXUIElementPerformAction(item.1, kAXPressAction as CFString)
                trace?("chose '\(item.0)': \(result.rawValue)")
                return result == .success
            }
            trace?("no 'Show in main channel' in the menu: \(items.map(\.0))")
            AXUIElementPerformAction(more, kAXPressAction as CFString)  // close the menu again
            return false
        }
        trace?("could not reach the task's menu")
        return false
    }

    /// Every item of whatever menu is open in Claude's window.
    private func menuItems(_ root: AXUIElement) -> [(String, AXUIElement)] {
        var items: [(String, AXUIElement)] = []
        var seen = 0
        func collect(_ e: AXUIElement, _ depth: Int) {
            seen += 1
            guard seen < 5_000, depth < 60 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if role == "AXMenuItem" || role == "AXMenuItemCheckbox" || role == "AXMenuItemRadio" {
                items.append((label(e), e))
                return
            }
            for child in children(e) { collect(child, depth + 1) }
        }
        for window in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { collect(window, 0) }
        return items
    }

    /// Scrolls Duet's conversation to the most recent message that mentions the task.
    ///
    /// Duet keeps only the latest stretch of the conversation loaded. With `loadEarlier`, a task
    /// that has scrolled out of that stretch is hunted for by jumping to the oldest loaded message,
    /// which makes Duet fetch the ones before it, and looking again, until it turns up or Duet
    /// stops producing older messages.
    @discardableResult
    private func scrollDiscussion(to task: DuetTask, in page: AXUIElement, loadEarlier: Bool = false,
                                  trace: ((String) -> Void)?) -> Bool {
        func scan() -> (mentions: [AXUIElement], articles: [AXUIElement]) {
            var mentions: [AXUIElement] = []
            var articles: [AXUIElement] = []
            var visited = 0
            func walk(_ e: AXUIElement, _ depth: Int) {
                visited += 1
                guard visited < 6_000, depth < 60 else { return }
                let subrole = attr(e, kAXSubroleAttribute) as? String
                // The Tasks pane lists the same title; only the conversation counts here.
                if subrole == "AXLandmarkRegion", label(e) == "Tasks" { return }
                if subrole == "AXDocumentArticle" { articles.append(e) }
                if attr(e, kAXRoleAttribute) as? String == "AXLink", label(e).contains(task.title) {
                    mentions.append(e)
                    return
                }
                for child in children(e) { walk(child, depth + 1) }
            }
            walk(page, 0)
            return (mentions, articles)
        }
        func y(_ e: AXUIElement) -> Int {
            var point = CGPoint.zero
            if let value = attr(e, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgPoint, &point)
            }
            return Int(point.y)
        }

        var stalled = 0
        var lastCount = -1
        for round in 0..<(loadEarlier ? 40 : 1) {
            let found = scan()
            if let target = found.mentions.last {
                let before = y(target)
                let result = AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
                Thread.sleep(forTimeInterval: 0.5)
                trace?("round \(round): found \(found.mentions.count) mention(s) among \(found.articles.count) messages; scrolled \(result.rawValue), y \(before) -> \(y(target))")
                return result == .success
            }
            guard loadEarlier, let oldest = found.articles.first else { return false }
            stalled = found.articles.count == lastCount ? stalled + 1 : 0
            lastCount = found.articles.count
            if stalled >= 4 {
                trace?("round \(round): no older messages are loading (\(found.articles.count) loaded); not found")
                return false
            }
            AXUIElementPerformAction(oldest, "AXScrollToVisible" as CFString)
            Thread.sleep(forTimeInterval: 0.6)
        }
        return false
    }

    private func duetPage(_ root: AXUIElement) -> AXUIElement? {
        for window in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if let page = find(in: window, budget: 60, maxDepth: 12, where: { e in
                guard self.attr(e, kAXRoleAttribute) as? String == "AXWebArea",
                      let url = (self.attr(e, kAXURLAttribute) as? URL)?.absoluteString else { return false }
                return url.contains("claude.ai/messages")
            }) { return page }
        }
        return nil
    }

    /// Depth-first search for the first element matching a test, giving up after `budget` elements.
    private func find(in e: AXUIElement, budget: Int, maxDepth: Int = 40, where test: (AXUIElement) -> Bool) -> AXUIElement? {
        AX.find(in: e, budget: budget, maxDepth: maxDepth, where: test)
    }

    private func claudeRoot() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        if preparedPid != app.processIdentifier {
            // Electron only builds its accessibility tree when a client asks for it.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            preparedPid = app.processIdentifier
            Thread.sleep(forTimeInterval: 1.5)
        }
        return root
    }

    private struct Scan {
        var chatTab = false
        var chatTabButton: AXUIElement?
        var recents: [ChatItem] = []
        var buttons: [String: AXUIElement] = [:]
        /// Every sidebar row with the status text Claude shows beside it, if any.
        var rows: [(title: String, badge: String?, section: String)] = []
    }

    // The shared helpers live in AXHelpers.swift; these keep the many call sites here short.
    private func attr(_ e: AXUIElement, _ name: String) -> AnyObject? { AX.attr(e, name) }
    private func children(_ e: AXUIElement) -> [AXUIElement] { AX.children(e) }
    private func label(_ e: AXUIElement) -> String { AX.label(e) }

    private func staticTexts(in e: AXUIElement, depth: Int) -> [String] {
        guard depth < 4 else { return [] }
        var out: [String] = []
        for child in children(e) {
            if attr(child, kAXRoleAttribute) as? String == "AXStaticText" {
                let text = label(child)
                if !text.isEmpty { out.append(text) }
            } else {
                out += staticTexts(in: child, depth: depth + 1)
            }
        }
        return out
    }

    /// Diagnostic: samples the sidebar's per-row status text alongside Claude's own session files,
    /// to learn what each looks like while a session is waiting on the user.
    func watch(to path: String, seconds: Int) {
        var log: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        while Date() < end {
            var line = "\(stamp.string(from: Date())) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
            if let root = claudeRoot(), let scan = scanSidebar(root) {
                line += " chatTab=\(scan.chatTab)"
                for row in scan.rows where row.badge != nil {
                    line += "\n    sidebar: \(row.title.prefix(28)) => \(row.badge ?? "")"
                }
            }
            let dir = home.appendingPathComponent(".claude/sessions")
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                line += "\n    live: \(((d["name"] as? String) ?? "").prefix(28)) status=\(d["status"] ?? "-") waitingFor=\(d["waitingFor"] ?? "-")"
            }
            log.append(line)
            try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// Diagnostic: the raw accessibility text of Claude's usage ring, every attribute.
    func debugUsageLabel() -> String {
        guard AXIsProcessTrusted(), let root = claudeRoot() else { return "no access" }
        var out: [String] = []
        for window in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if let ring = find(in: window, budget: 4_000, maxDepth: 70, where: { e in
                self.attr(e, kAXRoleAttribute) as? String == "AXPopUpButton" && self.label(e).hasPrefix("Usage")
            }) {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                    out.append("\(name): \((attr(ring, name) as? String) ?? "-")")
                }
                out.append("children: \(staticTexts(in: ring, depth: 0))")
            }
        }
        return out.isEmpty ? "usage ring not found" : out.joined(separator: "\n")
    }

    /// Diagnostic: what one sidebar pass found, as counts only.
    func debugSummary() -> String {
        guard AXIsProcessTrusted() else { return "not trusted" }
        guard let root = claudeRoot() else { return "Claude not running" }
        guard let scan = scanSidebar(root) else { return "sidebar not found" }
        return "chatTab=\(scan.chatTab) tabButton=\(scan.chatTabButton != nil) rows=\(scan.buttons.count) recents=\(scan.recents.count)"
    }

    private func findSidebar(_ e: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        budget -= 1
        guard budget > 0, depth < 30 else { return nil }
        if attr(e, kAXSubroleAttribute) as? String == "AXLandmarkComplementary", label(e) == "Sidebar" { return e }
        for child in children(e) {
            if let found = findSidebar(child, depth: depth + 1, budget: &budget) { return found }
        }
        return nil
    }

    /// One pass over the sidebar in reading order. A row is a button holding the title as its first
    /// text, followed by a "More options for <title>" menu; the nearest heading above names its section.
    private func scanSidebar(_ root: AXUIElement) -> Scan? {
        var budget = 600
        guard let sidebar = findSidebar(root, depth: 0, budget: &budget) else { return nil }
        var scan = Scan()
        var heading = ""
        var candidates: [String: (element: AXUIElement, badge: String?)] = [:]
        var visited = 0

        func walk(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 1_500, depth < 40 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            switch role {
            case "AXRadioButton":
                if label(e) == "Claude" {
                    scan.chatTabButton = e
                    scan.chatTab = (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1
                }
            case "AXHeading":
                heading = label(e)
            case "AXButton":
                // The texts sit a wrapper or two below the button.
                let texts = staticTexts(in: e, depth: 0)
                if let title = texts.first {
                    candidates[title] = (e, texts.count > 1 ? texts[1] : nil)
                }
            case "AXPopUpButton":
                let text = label(e)
                let prefix = "More options for "
                if text.hasPrefix(prefix) {
                    let title = String(text.dropFirst(prefix.count))
                    if let c = candidates[title], title != heading {
                        scan.buttons[title] = c.element
                        scan.rows.append((title, c.badge, heading))
                        if heading == "Recents" {
                            scan.recents.append(ChatItem(title: title, badge: c.badge))
                        }
                    }
                }
            default:
                break
            }
            for child in children(e) { walk(child, depth + 1) }
        }
        walk(sidebar, 0)
        return scan
    }
}
