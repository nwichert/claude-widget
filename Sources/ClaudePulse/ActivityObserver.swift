import AppKit
import ApplicationServices
import Combine

/// Opt-in record of what is in front of you: the app, the window title and the text visible in
/// that window, read through the Accessibility API. No screenshots are taken.
///
/// Entries go to `~/Library/Application Support/ClaudePulse/activity/YYYY-MM-DD.jsonl`, which
/// `tools/activity_stats.py` summarises for a Claude session that suggests skills. Nothing is
/// recorded unless "Watch my screen to suggest skills" is on, and nothing here leaves the Mac.
final class ActivityObserver: ObservableObject {
    struct SeenApp: Equatable, Identifiable {
        var bundle: String
        var name: String
        var id: String { bundle }
    }

    struct Capture: Equatable {
        var bundle: String
        var app: String
        var title: String
        var text: String
    }

    @Published private(set) var entriesToday = 0
    @Published private(set) var lastWriteAt: Date?
    /// Apps recently in front while observing, offered in settings as ones to exclude.
    @Published private(set) var recentApps: [SeenApp] = []

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudePulse/activity")

    private static let interval = 10
    /// A window whose text keeps changing (a clock, a log) still gets at most one entry a minute.
    private static let minimumEntrySeconds: TimeInterval = 60
    private static let nodeBudget = 1_500
    private static let textLimit = 2_000

    /// Never recorded, whatever the exclusion list says: the lock screen and screen saver.
    private static let systemSkipped: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    private let queue = DispatchQueue(label: "claude-pulse.activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Everything below is touched only on `queue`.
    private var pending: (capture: Capture, start: Date, lastSeen: Date)?
    private var countedDay = ""
    private var count = 0
    private var ticks = 0
    private var seenApps: [SeenApp] = []

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: .seconds(Self.interval), leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Writes the entry still held in memory. Called on quit.
    func stop() {
        queue.sync { flush() }
    }

    /// Removes everything recorded so far.
    func deleteAll() {
        queue.async {
            self.pending = nil
            try? FileManager.default.removeItem(at: Self.directory)
            self.count = 0
            DispatchQueue.main.async {
                self.entriesToday = 0
                self.lastWriteAt = nil
            }
        }
    }

    // MARK: - Loop

    private func tick() {
        // Old files expire even while watching is off.
        if ticks % 360 == 0 { prune() }
        ticks += 1

        guard Settings.bool(Settings.Key.observeScreen, default: false),
              !Settings.bool(Settings.Key.observePaused, default: false),
              AXIsProcessTrusted(),
              !Self.screenLocked(),
              let capture = Self.capture(excluded: Set(Settings.excludedApps()))
        else {
            flush()
            return
        }

        let now = Date()
        remember(SeenApp(bundle: capture.bundle, name: capture.app))
        if let held = pending {
            let sameWindow = held.capture.bundle == capture.bundle && held.capture.title == capture.title
            let sameText = held.capture.text == capture.text
            if sameWindow && (sameText || now.timeIntervalSince(held.start) < Self.minimumEntrySeconds) {
                pending?.lastSeen = now
                return
            }
            flush()
        }
        pending = (capture, now, now)
    }

    private func remember(_ app: SeenApp) {
        guard seenApps.first != app else { return }
        seenApps.removeAll { $0.bundle == app.bundle }
        seenApps.insert(app, at: 0)
        seenApps = Array(seenApps.prefix(8))
        let apps = seenApps
        DispatchQueue.main.async { self.recentApps = apps }
    }

    // MARK: - Reading the front window

    private static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /// What would be recorded right now, or nil when the front app or window is one to skip.
    static func capture(excluded: Set<String>) -> Capture? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier,
              front.processIdentifier != getpid(),
              !excluded.contains(bundle),
              !systemSkipped.contains(bundle)
        else { return nil }

        let root = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        var window: AXUIElement?
        if let value = AX.attr(root, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = (value as! AXUIElement)
        }
        let title = window.flatMap { AX.attr($0, kAXTitleAttribute) as? String } ?? ""
        // Private browsing windows say so in their title.
        let lowered = title.lowercased()
        if lowered.contains("private") || lowered.contains("incognito") { return nil }

        let text = window.map(visibleText) ?? ""
        return Capture(bundle: bundle,
                       app: front.localizedName ?? bundle,
                       title: redact(title),
                       text: redact(text))
    }

    /// Labels and static text in a window. Never the contents of a field you can type in, and
    /// nothing at all from a window that holds a password field.
    private static func visibleText(_ window: AXUIElement) -> String {
        var left = nodeBudget
        var length = 0
        var parts: [String] = []
        var seen = Set<String>()
        var secure = false

        func add(_ raw: String?) {
            guard let raw else { return }
            let clean = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            guard clean.count >= 2, !seen.contains(clean) else { return }
            seen.insert(clean)
            let piece = String(clean.prefix(300))
            parts.append(piece)
            length += piece.count + 1
        }

        func name(_ e: AXUIElement) -> String? {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = AX.attr(e, attribute) as? String, !s.isEmpty { return s }
            }
            return nil
        }

        func walk(_ e: AXUIElement, _ depth: Int) {
            left -= 1
            guard left > 0, depth < 40, length < textLimit, !secure else { return }
            if AX.attr(e, kAXSubroleAttribute) as? String == "AXSecureTextField" {
                secure = true
                return
            }
            let role = AX.attr(e, kAXRoleAttribute) as? String ?? ""
            switch role {
            case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
                // The field's name only. Its value is what you typed, and its children repeat it.
                add(name(e))
                return
            case "AXStaticText":
                add(AX.label(e))
                return
            case "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuItem":
                add(name(e))
                return
            case "AXLink", "AXHeading", "AXTab":
                add(name(e))
            case "AXScrollBar", "AXImage", "AXMenuBar":
                return
            default:
                break
            }
            // Long tables and lists report the rows actually on screen separately.
            var children: [AXUIElement] = []
            if ["AXTable", "AXOutline", "AXList"].contains(role) {
                children = (AX.attr(e, kAXVisibleRowsAttribute) as? [AXUIElement])
                    ?? (AX.attr(e, kAXVisibleChildrenAttribute) as? [AXUIElement]) ?? []
            }
            if children.isEmpty { children = AX.children(e) }
            for child in children { walk(child, depth + 1) }
        }

        walk(window, 0)
        if secure { return "" }
        return String(parts.joined(separator: "\n").prefix(textLimit))
    }

    // MARK: - Redaction

    private static let redactions: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[email]"),
            // Card, account and phone numbers: nine or more digits, however they are grouped.
            (#"(?<![\w.])(?:\d[ \-]?){8,}\d(?![\w])"#, "[number]"),
            // Keys and tokens: a long unbroken run mixing letters and digits.
            (#"(?<![\w\-+=])(?=[\w\-+=]*\d)(?=[\w\-+=]*[A-Z])[\w\-+=]{24,}(?![\w\-+=])"#, "[token]"),
        ]
        return patterns.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, replacement) }
        }
    }()

    /// Pattern-based, so it will miss things. The exclusion list and the pause switch are the
    /// real safeguards.
    static func redact(_ text: String) -> String {
        var out = text
        for (regex, replacement) in redactions {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: replacement)
        }
        return out
    }

    // MARK: - Storage

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let stamp = ISO8601DateFormatter()

    private func flush() {
        guard let held = pending else { return }
        pending = nil
        let seconds = Int(held.lastSeen.timeIntervalSince(held.start)) + Self.interval
        let entry: [String: Any] = [
            "at": Self.stamp.string(from: held.start),
            "seconds": seconds,
            "bundle": held.capture.bundle,
            "app": held.capture.app,
            "title": held.capture.title,
            "text": held.capture.text,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)

        let fm = FileManager.default
        let day = Self.dayFormat.string(from: held.start)
        let file = Self.directory.appendingPathComponent(day + ".jsonl")
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: line)) != nil else { return }

        if countedDay != day {
            countedDay = day
            // Entries written before this launch count too.
            count = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
        } else {
            count += 1
        }
        let total = count
        let now = Date()
        DispatchQueue.main.async {
            self.entriesToday = total
            self.lastWriteAt = now
        }
    }

    /// Deletes day files older than the retention setting.
    private func prune() {
        let days = max(1, Settings.int(Settings.Key.observeRetentionDays, default: 7))
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let cutoff = Self.dayFormat.string(from: cutoffDate)
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            // File names are dates, so plain string order is date order.
            if file.deletingPathExtension().lastPathComponent < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Diagnostics

    /// Diagnostic: what would be recorded from the front window, sampled every two seconds.
    /// Ignores the on/off switch but keeps every skip rule, and writes nothing to the activity folder.
    static func probe(to path: String, seconds: Int) {
        var log: [String] = []
        func flush() { try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        guard AXIsProcessTrusted() else { log.append("no Accessibility access"); flush(); return }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        var last: Capture?
        while Date() < end {
            let front = NSWorkspace.shared.frontmostApplication
            let time = clock.string(from: Date())
            if screenLocked() {
                log.append("\(time) skipped: screen locked")
            } else if let capture = capture(excluded: Set(Settings.excludedApps())) {
                if capture != last {
                    log.append("\(time) \(capture.app) [\(capture.bundle)]")
                    log.append("    title: \(capture.title.isEmpty ? "(none)" : capture.title)")
                    log.append("    text (\(capture.text.count) chars): "
                               + (capture.text.isEmpty ? "(none exposed)" : capture.text.replacingOccurrences(of: "\n", with: " | ")))
                }
                last = capture
            } else {
                log.append("\(time) skipped: \(front?.localizedName ?? "?") [\(front?.bundleIdentifier ?? "?")]")
                last = nil
            }
            flush()
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// A readable name for a bundle id, for the exclusion list.
    static func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
