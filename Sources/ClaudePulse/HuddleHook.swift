import Foundation

/// `ClaudePulse --huddle-hook`: the PermissionRequest hook Claude Code runs before asking you to
/// approve a tool call or answer an AskUserQuestion.
///
/// Claude Code shows its own prompt and runs this hook at the same time; whichever is answered
/// first wins and the other is withdrawn. So the hook hands the request to the huddle and waits.
/// If you answer in the huddle, it prints the decision; if you answer in Claude instead, Claude
/// ends the hook. When Pulse is not running it steps aside at once, printing nothing, which leaves
/// Claude's normal prompt as the only one.
enum HuddleHook {
    /// The request file, kept where the signal handler can reach it.
    private static var requestPath: UnsafeMutablePointer<CChar>?

    static func runIfRequested() {
        guard CommandLine.arguments.contains(HuddleHookInstaller.marker) else { return }
        run()
        exit(0)
    }

    private static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              event["hook_event_name"] as? String == "PermissionRequest" else { return }

        let fm = FileManager.default
        // Only wait when Pulse is up to show the request; otherwise stay out of the way.
        func pulseAlive() -> Bool {
            guard let m = (try? fm.attributesOfItem(atPath: HuddleStore.heartbeat.path))?[.modificationDate] as? Date
            else { return false }
            return Date().timeIntervalSince(m) < 6
        }
        guard pulseAlive() else { return }

        let id = UUID().uuidString.lowercased()
        let request = HuddleStore.requestsDir.appendingPathComponent(id + ".json")
        let response = HuddleStore.responsesDir.appendingPathComponent(id + ".json")
        try? fm.createDirectory(at: HuddleStore.requestsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: HuddleStore.responsesDir, withIntermediateDirectories: true)

        let record: [String: Any] = [
            "id": id,
            "pid": Int(getpid()),
            "session_id": event["session_id"] as? String ?? "",
            "cwd": event["cwd"] as? String ?? "",
            "transcript_path": event["transcript_path"] as? String ?? "",
            "tool_name": event["tool_name"] as? String ?? "",
            "tool_input": event["tool_input"] as? [String: Any] ?? [:],
            "created": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              (try? data.write(to: request, options: .atomic)) != nil else { return }

        // Claude ends the hook when you answer its own prompt: tidy up so the card closes.
        requestPath = strdup(request.path)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] {
            signal(sig) { _ in
                if let p = HuddleHook.requestPath { unlink(p) }
                _exit(0)
            }
        }
        defer { try? fm.removeItem(at: request) }

        let deadline = Date().addingTimeInterval(590)
        var lastAliveCheck = Date()
        while Date() < deadline {
            if let answer = try? Data(contentsOf: response), !answer.isEmpty {
                try? fm.removeItem(at: response)
                FileHandle.standardOutput.write(answer)
                return
            }
            // Claude itself went away.
            if getppid() == 1 { return }
            if Date().timeIntervalSince(lastAliveCheck) > 3 {
                lastAliveCheck = Date()
                if !pulseAlive() { return }  // Pulse quit: Claude's own prompt is all there is
                if !fm.fileExists(atPath: request.path) { return }
            }
            usleep(150_000)
        }
    }
}
