import AppKit
import Combine
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = SessionStore()
    private let chats = ChatReader()
    private let artifacts = ArtifactStore()
    private let github = GitHubReader()
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    private let notifyKey = "notifyOnFinish"
    private let remindKey = "remindWhenWaiting"
    private let panelHiddenKey = "panelHidden"

    /// Notifications need a real app bundle; `swift run` has none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }
    private var notifyEnabled: Bool {
        get { Settings.shared.notifyOnFinish }
        set { Settings.shared.notifyOnFinish = newValue }
    }

    private var remindEnabled: Bool {
        get { Settings.shared.remindMinutes > 0 }
        set { Settings.shared.remindMinutes = newValue ? 15 : 0 }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--chat-debug"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.global().async { [chats] in
                try? chats.debugSummary().write(toFile: path, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ax-probe"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.global().async {
                AXProbe.run(to: path,
                            verbose: CommandLine.arguments.contains("--verbose"),
                            waitForChatTab: CommandLine.arguments.contains("--wait-chat"))
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }

        panel = PanelController(store: store, chats: chats, artifacts: artifacts, github: github) { [weak self] row in self?.open(row) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        renderStatus(rows: [])

        store.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.renderStatus(rows: $0) }
            .store(in: &cancellables)

        store.onFinished = { [weak self] row in self?.notify(row) }
        store.onReminder = { [weak self] row in self?.notify(row, reminder: true) }

        if canNotify {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        store.start()
        chats.start()
        artifacts.onNewMentions = { [weak self] item in self?.notifyMention(item) }
        artifacts.start()
        github.start()

        // `ClaudePulse --snapshot out.png` renders the panel to a file and quits (for checking layout).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            if CommandLine.arguments.contains("--demo-done") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [store] in store.debugForceDone() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--slow") ? 14 : 3)) { [panel] in
                panel?.snapshot(to: path,
                                settings: CommandLine.arguments.contains("--settings"),
                                minimized: CommandLine.arguments.contains("--minimized") ? true : nil)
                NSApp.terminate(nil)
            }
            return
        }

        if !UserDefaults.standard.bool(forKey: panelHiddenKey) { panel.show() }
    }

    // MARK: - Menu bar

    private func renderStatus(rows: [SessionRow]) {
        guard let button = statusItem.button else { return }
        let waiting = rows.filter { $0.state == .needsYou }.count
        let working = rows.filter { $0.state == .working }.count
        let symbol = waiting > 0 ? "circle.fill" : working > 0 ? "circle.dotted" : "circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude sessions")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        image?.isTemplate = true
        button.image = image
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.toolTip = "\(waiting) done and waiting on you · \(working) working"
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle()
            UserDefaults.standard.set(!panel.isVisible, forKey: panelHiddenKey)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: panel.isVisible ? "Hide panel" : "Show panel",
                     action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Sessions waiting for you",
                     action: #selector(openWaiting), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset panel size",
                     action: #selector(resetPanelSize), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let notifyItem = menu.addItem(withTitle: "Notify when a session finishes",
                                      action: #selector(toggleNotify), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = notifyEnabled ? .on : .off
        notifyItem.isEnabled = canNotify

        let remindItem = menu.addItem(withTitle: "Remind me once if a session is still waiting",
                                      action: #selector(toggleRemind), keyEquivalent: "")
        remindItem.target = self
        remindItem.state = remindEnabled ? .on : .off
        remindItem.isEnabled = canNotify

        let loginItem = menu.addItem(withTitle: "Open at login",
                                     action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItem.isEnabled = canNotify

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // so the next left click toggles the panel again
    }

    @objc private func togglePanel() {
        panel.toggle()
        UserDefaults.standard.set(!panel.isVisible, forKey: panelHiddenKey)
    }

    @objc private func resetPanelSize() { panel.resetSize() }

    @objc private func openWaiting() {
        if let url = URL(string: "claude://code/needs-input") { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleNotify() { notifyEnabled.toggle() }
    @objc private func toggleRemind() { remindEnabled.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Opening sessions

    private func open(_ row: SessionRow) {
        if let url = row.openURL {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID),
                  row.cliSessionId == nil {
            NSWorkspace.shared.open(app)
        }
    }

    // MARK: - Notifications

    private func notify(_ row: SessionRow, reminder: Bool = false) {
        guard canNotify, reminder ? remindEnabled : notifyEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = row.title
        if reminder {
            content.body = "Still waiting on you · \(Format.ago(row.lastActivity)) · \(row.project)"
        } else {
            content.body = row.waitingFor.map { "Waiting for \($0) · \(row.project)" } ?? "Finished · \(row.project)"
        }
        content.sound = .default
        if let url = row.openURL { content.userInfo = ["url": url.absoluteString] }
        // One notification per session: a newer one replaces the older.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: row.id, content: content, trigger: nil))
    }

    private func notifyMention(_ item: ArtifactItem) {
        guard canNotify, notifyEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = "\(item.lastCommentBy ?? "Someone") tagged you" + (item.mentionPreview.map { ": \($0)" } ?? "")
        content.sound = .default
        content.userInfo = ["url": item.url]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: item.url, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
