import AppKit
import ApplicationServices

/// Diagnostic for the chat-rows experiment: `open ClaudePulse.app --args --ax-probe out.txt`.
/// Asks for Accessibility access if needed, waits for it, then writes the *shape* of Claude
/// Desktop's accessibility tree (roles and link targets, with titles reduced to their length).
enum AXProbe {
    /// Diagnostic: follows Claude's window for a while and writes down each page it shows
    /// (address, then the labelled elements on it), so an unfamiliar screen can be mapped.
    static func follow(to path: String, seconds: Int) {
        var log: [String] = []
        func flush() { try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first else {
            log.append("no access or Claude not running"); flush(); return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func redact(_ s: String) -> String {
            s.replacingOccurrences(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f-]{22}"#, with: "<uuid>", options: .regularExpression)
        }
        func pages(_ e: AXUIElement, _ depth: Int, _ out: inout [(String, AXUIElement)]) {
            guard depth < 12 else { return }
            if attr(e, kAXRoleAttribute) as? String == "AXWebArea",
               let url = (attr(e, kAXURLAttribute) as? URL)?.absoluteString, url.hasPrefix("http") {
                out.append((redact(url), e))
            }
            for child in kids(e) { pages(child, depth + 1, &out) }
        }
        var budget = 0
        func dump(_ e: AXUIElement, _ depth: Int) {
            budget -= 1
            guard budget > 0, depth < 70 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? "?"
            let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
            let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { attr(e, $0) as? String }.filter { !$0.isEmpty }
            let label = text.first ?? ""
            if !label.isEmpty || ["AXHeading", "AXList", "AXRadioButton", "AXTab", "AXLink"].contains(role) {
                log.append("\(String(repeating: " ", count: min(depth, 40)))\(role) \(sub) \(label.prefix(70))")
            }
            for child in kids(e) { dump(child, depth + 1) }
        }

        var last = ""
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        while Date() < end {
            var found: [(String, AXUIElement)] = []
            let windows = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            for w in windows { pages(w, 0, &found) }
            let key = "\(windows.count)|" + found.map(\.0).joined(separator: " ")
            if key != last {
                last = key
                Thread.sleep(forTimeInterval: 2.5)  // let the page finish drawing
                log.append("=== \(stamp.string(from: Date())) windows=\(windows.count) \(found.map(\.0).joined(separator: " , "))")
                for (_, element) in found { budget = 900; dump(element, 0) }
                flush()
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        log.append("=== end")
        flush()
    }

    static func run(to path: String, verbose: Bool = false, waitForChatTab: Bool = false, waitForURL: String? = nil) {
        var log: [String] = []
        func flush() { try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        var trusted = AXIsProcessTrustedWithOptions(prompt)
        log.append("trusted at launch: \(trusted)")
        flush()
        var waited = 0
        while !trusted && waited < 600 {
            Thread.sleep(forTimeInterval: 2)
            waited += 2
            trusted = AXIsProcessTrusted()
        }
        log.append("trusted after \(waited)s: \(trusted)")
        guard trusted else { flush(); return }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first else {
            log.append("Claude is not running"); flush(); return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Electron builds its accessibility tree only when asked.
        let set = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        log.append("AXManualAccessibility: \(set.rawValue)")
        Thread.sleep(forTimeInterval: 2)

        func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func redact(_ s: String) -> String {
            s.replacingOccurrences(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f-]{22}"#, with: "<uuid>", options: .regularExpression)
        }
        var count = 0
        var roles: [String: Int] = [:]
        func walk(_ e: AXUIElement, _ depth: Int) {
            count += 1
            guard count < 8000, depth < 80 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? "?"
            roles[role, default: 0] += 1
            if verbose, ["AXButton", "AXStaticText", "AXRadioButton", "AXHeading", "AXPopUpButton", "AXCheckBox", "AXList", "AXGroup"].contains(role) {
                let title = (attr(e, kAXTitleAttribute) as? String) ?? ""
                let desc = (attr(e, kAXDescriptionAttribute) as? String) ?? ""
                let value = (attr(e, kAXValueAttribute) as? String) ?? ""
                let sub = (attr(e, kAXSubroleAttribute) as? String) ?? ""
                let text = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
                if role != "AXGroup" || !text.isEmpty || !sub.isEmpty {
                    log.append("\(String(repeating: " ", count: min(depth, 40)))\(role) \(sub) \(String(text.prefix(60)))")
                }
            } else if ["AXLink", "AXWebArea", "AXHeading", "AXRadioButton", "AXTab", "AXList"].contains(role) {
                let title = (attr(e, kAXTitleAttribute) as? String) ?? ""
                let desc = (attr(e, kAXDescriptionAttribute) as? String) ?? ""
                let url = (attr(e, kAXURLAttribute) as? URL)?.absoluteString ?? ""
                let kids = (attr(e, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0
                log.append("\(String(repeating: " ", count: min(depth, 30)))\(role) title=\(title.count) desc=\(desc.count) kids=\(kids) \(redact(url))")
            }
            for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
        }
        if waitForChatTab {
            // Chats are only in the tree while the sidebar's "Claude" tab is selected.
            func chatTabSelected(_ e: AXUIElement, _ depth: Int) -> Bool {
                guard depth < 40 else { return false }
                if attr(e, kAXRoleAttribute) as? String == "AXRadioButton",
                   (attr(e, kAXTitleAttribute) as? String) == "Claude" || (attr(e, kAXDescriptionAttribute) as? String) == "Claude" {
                    return (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1
                }
                for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where chatTabSelected(child, depth + 1) {
                    return true
                }
                return false
            }
            var seconds = 0
            while seconds < 900 && !chatTabSelected(root, 0) {
                Thread.sleep(forTimeInterval: 1.5)
                seconds += 2
            }
            log.append("chat tab selected after ~\(seconds)s")
            Thread.sleep(forTimeInterval: 2)
        }
        if let wanted = waitForURL?.lowercased() {
            // Wait until the page showing in Claude's window has this text in its address.
            func pageURLs(_ e: AXUIElement, _ depth: Int, _ out: inout [String]) {
                guard depth < 12 else { return }
                if attr(e, kAXRoleAttribute) as? String == "AXWebArea",
                   let url = (attr(e, kAXURLAttribute) as? URL)?.absoluteString {
                    out.append(url)
                }
                for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { pageURLs(child, depth + 1, &out) }
            }
            var seconds = 0
            var matched = false
            while seconds < 900 && !matched {
                var urls: [String] = []
                for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { pageURLs(w, 0, &urls) }
                matched = urls.contains { $0.lowercased().contains(wanted) }
                if !matched { Thread.sleep(forTimeInterval: 1.5); seconds += 2 }
            }
            log.append("page with '\(wanted)' open: \(matched) after ~\(seconds)s")
            flush()
            guard matched else { return }
            Thread.sleep(forTimeInterval: 3)
        }
        let windows = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        log.append("windows: \(windows.count)")
        windows.forEach { walk($0, 0) }
        log.append("elements: \(count)")
        log.append(roles.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        flush()
    }
}
