import AppKit
import ApplicationServices

/// Diagnostic for the chat-rows experiment: `open ClaudePulse.app --args --ax-probe out.txt`.
/// Asks for Accessibility access if needed, waits for it, then writes the *shape* of Claude
/// Desktop's accessibility tree (roles and link targets, with titles reduced to their length).
enum AXProbe {
    static func run(to path: String, verbose: Bool = false, waitForChatTab: Bool = false) {
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
        let windows = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        log.append("windows: \(windows.count)")
        windows.forEach { walk($0, 0) }
        log.append("elements: \(count)")
        log.append(roles.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        flush()
    }
}
