import AppKit
import ApplicationServices
import Combine

struct ChatItem: Identifiable, Equatable, Codable {
    var title: String
    /// Whatever Claude shows beside the title, e.g. "Includes an artifact".
    var badge: String?
    var id: String { title }
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
        guard Settings.bool(Settings.Key.showChats, default: true) else { return }
        let isTrusted = AXIsProcessTrusted()
        if isTrusted != trusted { DispatchQueue.main.async { self.trusted = isTrusted } }
        guard isTrusted, let root = claudeRoot(), let scan = scanSidebar(root), scan.chatTab else { return }

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
