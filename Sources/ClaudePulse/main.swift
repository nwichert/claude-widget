import AppKit
import Combine
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = SessionStore()
    private let chats = ChatReader()
    private let artifacts = ArtifactStore()
    private let github = GitHubReader()
    private let insights = InsightsStore()
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
        // Diagnostic: post one notification, to check delivery and the icon, then quit.
        if CommandLine.arguments.contains("--notify-test") {
            let content = UNMutableNotificationContent()
            content.title = "Claude Pulse"
            content.body = "Test notification. This should carry the Claude Pulse icon."
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "test-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            return
        }
        // Diagnostic: walk through completing the last remembered Duet task without ticking it.
        if CommandLine.arguments.contains("--complete-duet-dry") {
            let path = CommandLine.arguments.last ?? "/dev/null"
            var lines = ["tasks remembered: \(chats.duetTasks.count)"]
            let write = { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
            _ = write()
            if let task = chats.duetTasks.last {
                chats.completeDuet(task, dryRun: true) { line in lines.append(line); _ = write() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { NSApp.terminate(nil) }
            return
        }
        // Diagnostic: click the first remembered Duet task the way a row click does, then quit.
        if CommandLine.arguments.contains("--open-duet-first") {
            let path = CommandLine.arguments.last ?? "/dev/null"
            var lines = ["tasks remembered: \(chats.duetTasks.count)"]
            let write = { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
            _ = write()
            chats.openDuet(chats.duetTasks.first) { line in lines.append(line); _ = write() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { NSApp.terminate(nil) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ax-follow"), CommandLine.arguments.count > i + 2 {
            let path = CommandLine.arguments[i + 1]
            let seconds = Int(CommandLine.arguments[i + 2]) ?? 120
            DispatchQueue.global().async {
                AXProbe.follow(to: path, seconds: seconds)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ax-watch"), CommandLine.arguments.count > i + 2 {
            let path = CommandLine.arguments[i + 1]
            let seconds = Int(CommandLine.arguments[i + 2]) ?? 60
            DispatchQueue.global().async { [chats] in
                chats.watch(to: path, seconds: seconds)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
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
                            waitForChatTab: CommandLine.arguments.contains("--wait-chat"),
                            waitForURL: CommandLine.arguments.firstIndex(of: "--wait-url")
                                .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil })
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }

        panel = PanelController(store: store, chats: chats, artifacts: artifacts, github: github, insights: insights) { [weak self] row in self?.open(row) }

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
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                self?.checkNotificationAccess()
            }
            // Access can be switched off in System Settings at any time; keep the panel honest about it.
            Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.checkNotificationAccess()
            }
        }

        store.sidebar = { [chats] in chats.sidebar }
        store.start()
        chats.start()
        artifacts.onNewMentions = { [weak self] item in self?.notifyMention(item) }
        artifacts.onNewShare = { [weak self] item in self?.notifyShare(item) }
        chats.onDuetNeedsInput = { [weak self] task in self?.notifyDuet(task) }
        artifacts.start()
        github.start()
        insights.start()

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
        let waiting = rows.filter { $0.wantsYou }.count
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

        let notifyItem = menu.addItem(withTitle: "Notifications",
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

    private func checkNotificationAccess() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let access: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                // Allowed, but banners can still be turned off on their own.
                access = settings.alertSetting == .disabled ? "bannersOff" : "authorized"
            case .denied: access = "denied"
            case .notDetermined: access = "notDetermined"
            @unknown default: access = "unknown"
            }
            DispatchQueue.main.async {
                if Settings.shared.notificationAccess != access { Settings.shared.notificationAccess = access }
            }
        }
    }

    private func notify(_ row: SessionRow, reminder: Bool = false) {
        guard canNotify, notifyEnabled, Settings.shared.notifySessions, !reminder || remindEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = row.title
        let asking = row.state == .needsInput
        if reminder {
            content.body = "\(asking ? "Still waiting on your answer" : "Still waiting on you") · \(Format.ago(row.lastActivity)) · \(row.project)"
        } else if asking {
            content.body = (row.prompt.map { "Needs your answer: \($0)" } ?? "Needs your answer") + " · \(row.project)"
        } else {
            content.body = "Done. Get back to me · \(row.project)"
        }
        content.sound = .default
        if let url = row.openURL { content.userInfo = ["url": url.absoluteString] }
        // One notification per session: a newer one replaces the older.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: row.id, content: content, trigger: nil))
    }

    private func notifyDuet(_ task: DuetTask) {
        guard canNotify, notifyEnabled, Settings.shared.notifyDuet, Settings.shared.showDuet else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = "Duet needs your input" + (task.summary.map { ": \($0)" } ?? "")
        content.sound = .default
        content.userInfo = ["duetTask": task.title]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "duet-" + task.title, content: content, trigger: nil))
    }

    private func notifyShare(_ item: ArtifactItem) {
        guard canNotify, notifyEnabled, Settings.shared.notifyArtifacts else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = "An artifact was shared with you"
        content.sound = .default
        content.userInfo = ["url": item.url]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "share-" + item.url, content: content, trigger: nil))
    }

    private func notifyMention(_ item: ArtifactItem) {
        guard canNotify, notifyEnabled, Settings.shared.notifyArtifacts else { return }
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
        let info = response.notification.request.content.userInfo
        if let title = info["duetTask"] as? String, let task = chats.duetTasks.first(where: { $0.title == title }) {
            chats.openDuet(task)
        } else if let s = info["url"] as? String, let url = URL(string: s) {
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
