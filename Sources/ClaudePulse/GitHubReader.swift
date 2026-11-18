import Combine
import Foundation

struct PullRequest: Identifiable, Equatable {
    enum Kind: Equatable { case reviewRequested, mine }
    enum Status: Equatable {
        case reviewRequested, checksFailing, changesRequested, readyToMerge, checksRunning, awaitingReview, draft

        var label: String {
            switch self {
            case .reviewRequested: return "review requested"
            case .checksFailing: return "checks failing"
            case .changesRequested: return "changes requested"
            case .readyToMerge: return "ready to merge"
            case .checksRunning: return "checks running"
            case .awaitingReview: return "awaiting review"
            case .draft: return "draft"
            }
        }

        /// True when the next move is yours.
        var needsYou: Bool {
            switch self {
            case .reviewRequested, .checksFailing, .changesRequested, .readyToMerge: return true
            case .checksRunning, .awaitingReview, .draft: return false
            }
        }
    }

    var repo: String  // "owner/name"
    var number: Int
    var title: String
    var url: String
    var author: String
    var kind: Kind
    var status: Status

    var id: String { url }
}

/// Open pull requests that involve you, across every GitHub account the `gh` CLI is logged in to.
///
/// "Connecting GitHub" means being logged in with `gh auth login`: the widget asks `gh` for
/// everything and never stores a credential itself. Per refresh it makes two searches per account
/// (PRs you wrote, PRs waiting on your review) plus one lookup per PR you wrote for checks and reviews.
final class GitHubReader: ObservableObject {
    enum Connection: Equatable {
        case checking
        case noCLI
        case notLoggedIn
        case connected([String])
    }

    @Published private(set) var pullRequests: [PullRequest] = []
    @Published private(set) var connection: Connection = .checking

    private let queue = DispatchQueue(label: "claude-pulse.github", qos: .utility)
    private var timer: DispatchSourceTimer?
    private lazy var gh: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: .seconds(180), leeway: .seconds(15))
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func refreshNow() { queue.async { [weak self] in self?.refresh() } }

    private func refresh() {
        guard Settings.bool(Settings.Key.showGitHub, default: true) else { return }
        guard let gh else { publish([], .noCLI); return }

        // `gh auth status` prints one "Logged in to github.com account NAME" line per account.
        let status = run(gh, ["auth", "status"]).output
        let accounts = status.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "Logged in to github.com account ") else { return nil }
            return line[r.upperBound...].split(separator: " ").first.map(String.init)
        }
        guard !accounts.isEmpty else { publish([], .notLoggedIn); return }

        var found: [String: PullRequest] = [:]
        for account in accounts {
            // Each account's own token, handed straight back to `gh` for that account's queries.
            // It lives only in this process's memory for the length of the refresh.
            let token = run(gh, ["auth", "token", "--user", account]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let env = ["GH_TOKEN": token]

            for item in search(gh, ["--review-requested=@me"], env) {
                guard var pr = Self.parse(item, kind: .reviewRequested) else { continue }
                pr.status = .reviewRequested
                found[pr.url] = pr
            }
            for item in search(gh, ["--author=@me"], env) {
                guard var pr = Self.parse(item, kind: .mine), found[pr.url] == nil else { continue }
                pr.status = (item["isDraft"] as? Bool) == true ? .draft : detail(gh, pr.url, env)
                found[pr.url] = pr
            }
        }

        let sorted = found.values.sorted {
            if $0.status.needsYou != $1.status.needsYou { return $0.status.needsYou }
            return ($0.repo, $0.number) < ($1.repo, $1.number)
        }
        publish(sorted, .connected(accounts))
    }

    private func publish(_ prs: [PullRequest], _ connection: Connection) {
        DispatchQueue.main.async {
            if self.pullRequests != prs { self.pullRequests = prs }
            if self.connection != connection { self.connection = connection }
        }
    }

    private func search(_ gh: String, _ filter: [String], _ env: [String: String]) -> [[String: Any]] {
        let args = ["search", "prs", "--state", "open", "--limit", "30",
                    "--json", "repository,number,title,url,author,isDraft"] + filter
        let result = run(gh, args, env: env)
        guard result.ok, let data = result.output.data(using: .utf8) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
    }

    private static func parse(_ item: [String: Any], kind: PullRequest.Kind) -> PullRequest? {
        guard let url = item["url"] as? String,
              let number = (item["number"] as? NSNumber)?.intValue,
              let repo = (item["repository"] as? [String: Any])?["nameWithOwner"] as? String
        else { return nil }
        return PullRequest(repo: repo, number: number,
                           title: (item["title"] as? String) ?? "",
                           url: url,
                           author: ((item["author"] as? [String: Any])?["login"] as? String) ?? "",
                           kind: kind, status: .awaitingReview)
    }

    /// Checks and review state for a PR you wrote.
    private func detail(_ gh: String, _ url: String, _ env: [String: String]) -> PullRequest.Status {
        let result = run(gh, ["pr", "view", url, "--json", "reviewDecision,statusCheckRollup"], env: env)
        guard result.ok, let data = result.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .awaitingReview }

        var failing = false, running = false
        for check in (obj["statusCheckRollup"] as? [[String: Any]]) ?? [] {
            let conclusion = (check["conclusion"] as? String) ?? ""
            let state = (check["state"] as? String) ?? ""      // commit statuses
            let status = (check["status"] as? String) ?? ""    // check runs
            if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion)
                || ["FAILURE", "ERROR"].contains(state) {
                failing = true
            } else if (!status.isEmpty && status != "COMPLETED") || ["PENDING", "EXPECTED"].contains(state) {
                running = true
            }
        }
        let decision = (obj["reviewDecision"] as? String) ?? ""
        if failing { return .checksFailing }
        if decision == "CHANGES_REQUESTED" { return .changesRequested }
        if running { return .checksRunning }
        if decision == "APPROVED" { return .readyToMerge }
        return .awaitingReview
    }

    private func run(_ path: String, _ args: [String], env: [String: String] = [:]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        env.forEach { environment[$0.key] = $0.value }
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (false, "") }
        // A stuck network call must not stall every later refresh.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}
