import AppKit
import ApplicationServices
import Combine

struct ChatItem: Identifiable, Equatable, Codable {
    var title: String
    /// Whatever Claude shows beside the title, e.g. "Includes an artifact".
    var badge: String?
    var id: String { title }
}

/// A task from Claude Duet's Tasks pane.
struct DuetTask: Identifiable, Equatable, Codable {
    var title: String
    /// The group it sits under, as Duet words it: "Needs input", "Ready for review", ...
    var status: String
    var summary: String?
    var url: String?
    var id: String { title }

    var needsInput: Bool { status.lowercased().contains("input") }
    var readyForReview: Bool { status.lowercased().contains("review") }
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
        if let data = UserDefaults.standard.data(forKey: duetKey),
           let cached = try? JSONDecoder().decode([DuetTask].self, from: data) {
            duetTasks = cached
            // Whatever already needed input when the widget last looked is not news after a restart.
            duetAlerted = Set(cached.filter { $0.needsInput }.map(\.title))
            let t = UserDefaults.standard.double(forKey: duetSeenKey)
            duetSeenAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
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
        if Settings.bool(Settings.Key.showDuet, default: true) { readDuet(root) }
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

    // MARK: - Duet

    /// Duet is the page at claude.ai/messages. When it is showing, read the Active tab of its Tasks pane.
    private func readDuet(_ root: AXUIElement) {
        guard let page = duetPage(root), let pane = find(in: page, budget: 1_500, where: { e in
            self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
        }) else { return }

        var group = ""
        var activeTab = true
        var sawTabs = false
        var tasks: [DuetTask] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 1_200, depth < 40 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            switch role {
            case "AXRadioButton":
                // Tabs: Active, Up next, Scheduled, Resolved. Only the Active list is kept.
                sawTabs = true
                if (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1 {
                    activeTab = label(e) == "Active" || staticTexts(in: e, depth: 0).first == "Active"
                }
            case "AXHeading":
                // "Ready for review 3 tasks" -> "Ready for review"
                group = label(e).replacingOccurrences(of: #"\s+\d+\s+tasks?$"#, with: "", options: .regularExpression)
            case "AXLink":
                guard let title = staticTexts(in: e, depth: 0).first, !group.isEmpty else { break }
                // The link's own label reads "Title, Status, summary".
                var summary: String?
                let full = label(e)
                let prefix = "\(title), \(group), "
                if full.hasPrefix(prefix) { summary = String(full.dropFirst(prefix.count)) }
                let url = (attr(e, kAXURLAttribute) as? URL)?.absoluteString
                if !tasks.contains(where: { $0.title == title }) {
                    tasks.append(DuetTask(title: title, status: group, summary: summary?.isEmpty == false ? summary : nil, url: url))
                }
                return  // nothing useful below a task link
            default:
                break
            }
            for child in children(e) { walk(child, depth + 1) }
        }
        walk(pane, 0)
        // With a task's detail open, the pane shows that task instead of the list and has no tabs.
        // That is not an empty list, so leave the remembered tasks alone.
        guard sawTabs, activeTab else { return }

        tasks.sort { ($0.needsInput ? 0 : $0.readyForReview ? 1 : 2) < ($1.needsInput ? 0 : $1.readyForReview ? 1 : 2) }

        // Alert once per task when it starts needing input. The very first list ever read only
        // sets the baseline. Nothing fires while Claude is the front app: you can see Duet then.
        let waiting = Set(tasks.filter { $0.needsInput }.map(\.title))
        var fresh: [DuetTask] = []
        if let alerted = duetAlerted {
            let claudeIsFront = DispatchQueue.main.sync {
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
            if !alreadyOpen {
                if let scan = self.scanSidebar(root), !scan.chatTab, let tab = scan.chatTabButton {
                    AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    trace?("pressed the Claude tab")
                    Thread.sleep(forTimeInterval: 0.6)
                }
                var pressed = false
                for _ in 0..<12 where !pressed {
                    var budget = 600
                    if let sidebar = self.findSidebar(root, depth: 0, budget: &budget),
                       let button = self.find(in: sidebar, budget: 500, where: { e in
                           self.attr(e, kAXRoleAttribute) as? String == "AXButton" && self.label(e).hasPrefix("Claude Duet")
                       }) {
                        pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    } else {
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                }
                trace?("pressed the Claude Duet button: \(pressed)")
            }
            // Wait for the page and its Tasks pane to load, then press the matching task.
            guard let task else { return }
            for attempt in 0..<30 {
                let page = self.duetPage(root)
                let pane = page.flatMap { self.find(in: $0, budget: 1_500, where: { e in
                    self.attr(e, kAXSubroleAttribute) as? String == "AXLandmarkRegion" && self.label(e) == "Tasks"
                }) }
                let link = pane.flatMap { self.find(in: $0, budget: 1_200, where: { e in
                    self.attr(e, kAXRoleAttribute) as? String == "AXLink"
                        && self.staticTexts(in: e, depth: 0).first == task.title
                }) }
                if attempt % 5 == 0 || link != nil {
                    trace?("try \(attempt): page \(page != nil) pane \(pane != nil) link \(link != nil)")
                }
                if let link {
                    let result = AXUIElementPerformAction(link, kAXPressAction as CFString)
                    trace?("pressed: \(result.rawValue)")
                    return
                }
                Thread.sleep(forTimeInterval: 0.35)
            }
            trace?("gave up")
        }
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
        var left = budget
        func search(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            left -= 1
            guard left > 0, depth < maxDepth else { return nil }
            if test(e) { return e }
            for child in children(e) {
                if let found = search(child, depth + 1) { return found }
            }
            return nil
        }
        return search(e, 0)
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

    private func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func label(_ e: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = attr(e, name) as? String, !s.isEmpty { return s }
        }
        return ""
    }

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
