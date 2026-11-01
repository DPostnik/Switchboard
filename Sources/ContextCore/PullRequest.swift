import Foundation

/// A GitHub pull request as `gh pr view --json` reports it, reduced to what the branch badge and the PR watch need.
public struct PullRequestStatus: Equatable, Sendable {
    public enum State: String, Codable, Sendable { case open, draft, merged, closed }
    public enum ReviewDecision: String, Codable, Sendable { case approved, changesRequested, reviewRequired }
    public enum Mergeable: String, Codable, Sendable { case mergeable, conflicting, unknown }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State
    public var reviewDecision: ReviewDecision?
    public var mergeable: Mergeable
    public var checks: [PullRequestCheck]
    public var headRefName: String
    public var baseRefName: String

    public init(number: Int, title: String, url: String, state: State, reviewDecision: ReviewDecision? = nil,
                mergeable: Mergeable = .unknown, checks: [PullRequestCheck] = [], headRefName: String = "", baseRefName: String = "") {
        self.number = number; self.title = title; self.url = url; self.state = state; self.reviewDecision = reviewDecision
        self.mergeable = mergeable; self.checks = checks; self.headRefName = headRefName; self.baseRefName = baseRefName
    }

    public var isOpen: Bool { state == .open || state == .draft }
    public var checksSummary: PullRequestChecksSummary { PullRequestChecksSummary(checks) }
    public var failingChecks: [PullRequestCheck] { checks.filter { $0.outcome == .failed } }

    /// The fields `parse` reads; one `gh pr view` call.
    public static let fields = "number,title,url,state,isDraft,reviewDecision,mergeable,statusCheckRollup,headRefName,baseRefName"

    /// Parses `gh pr view --json <fields>`. Unknown check kinds and values are tolerated; a missing number or
    /// state gives nil.
    public static func parse(_ data: Data) -> PullRequestStatus? {
        guard let raw = try? JSONDecoder().decode(RawPullRequest.self, from: data), let number = raw.number,
              let state = raw.state?.uppercased() else { return nil }
        let resolved: State
        switch state {
        case "MERGED": resolved = .merged
        case "CLOSED": resolved = .closed
        default: resolved = raw.isDraft == true ? .draft : .open
        }
        let review: ReviewDecision? = switch raw.reviewDecision?.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: nil
        }
        let mergeable: Mergeable = switch raw.mergeable?.uppercased() {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: .unknown
        }
        return PullRequestStatus(number: number, title: raw.title ?? "", url: raw.url ?? "", state: resolved,
                                 reviewDecision: review, mergeable: mergeable,
                                 checks: PullRequestCheck.latest(raw.statusCheckRollup ?? []),
                                 headRefName: raw.headRefName ?? "", baseRefName: raw.baseRefName ?? "")
    }
}

/// One CI check: a GitHub Actions/App check run or a commit status context.
public struct PullRequestCheck: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case passed, failed, pending, neutral }
    public var name: String
    public var workflow: String?
    public var outcome: Outcome
    /// The check's page (`detailsUrl` or `targetUrl`).
    public var link: String?

    public init(name: String, workflow: String? = nil, outcome: Outcome, link: String? = nil) {
        self.name = name; self.workflow = workflow; self.outcome = outcome; self.link = link
    }

    /// "Workflow / name" when the workflow is known, as GitHub lists it.
    public var displayName: String {
        guard let workflow, !workflow.isEmpty, workflow != name else { return name }
        return workflow + " / " + name
    }

    /// The GitHub Actions run behind the check (`…/actions/runs/<id>/job/…`), for `gh run view --log-failed`.
    public var runID: String? {
        guard let link, let range = link.range(of: "/actions/runs/") else { return nil }
        let digits = link[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// The rollup lists every run, re-runs and runs for other events included; the latest one per check counts.
    static func latest(_ entries: [RawCheck]) -> [PullRequestCheck] {
        var order: [String] = []
        var latest: [String: (started: String, check: PullRequestCheck)] = [:]
        for entry in entries {
            guard let check = entry.check else { continue }
            let key = (check.workflow ?? "") + "\n" + check.name, started = entry.startedAt ?? ""
            if let existing = latest[key] {
                if started >= existing.started { latest[key] = (started, check) }
            } else {
                order.append(key); latest[key] = (started, check)
            }
        }
        return order.compactMap { latest[$0]?.check }
    }
}

/// The badge's one-glyph view of the checks.
public enum PullRequestChecksSummary: Equatable, Sendable {
    /// No checks, or only skipped/neutral ones.
    case none
    case passing
    case pending(Int)
    case failing([String])

    public init(_ checks: [PullRequestCheck]) {
        let failed = checks.filter { $0.outcome == .failed }
        let pending = checks.filter { $0.outcome == .pending }.count
        if !failed.isEmpty { self = .failing(failed.map(\.displayName)) }
        else if pending > 0 { self = .pending(pending) }
        else if checks.contains(where: { $0.outcome == .passed }) { self = .passing }
        else { self = .none }
    }
}

/// A review or a conversation comment on the PR.
public struct PullRequestActivity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case review, comment }
    public var id: String
    public var kind: Kind
    public var author: String
    /// Review state (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`); nil for comments.
    public var reviewState: String?
    public var body: String
    public var date: String?
    /// Comments carry `viewerDidAuthor`; reviews are matched against the signed-in login.
    public var byViewer: Bool

    public init(id: String, kind: Kind, author: String, reviewState: String? = nil, body: String, date: String? = nil, byViewer: Bool = false) {
        self.id = id; self.kind = kind; self.author = author; self.reviewState = reviewState
        self.body = body; self.date = date; self.byViewer = byViewer
    }

    public static let fields = "reviews,comments"

    /// Parses `gh pr view --json reviews,comments`. Minimized comments and the viewer's own pending review are
    /// skipped; `viewer` marks the signed-in user's reviews.
    public static func parse(_ data: Data, viewer: String?) -> [PullRequestActivity] {
        guard let raw = try? JSONDecoder().decode(RawActivity.self, from: data) else { return [] }
        var result: [PullRequestActivity] = []
        for review in raw.reviews ?? [] {
            guard let id = review.id, review.state?.uppercased() != "PENDING" else { continue }
            let author = review.author?.login ?? ""
            result.append(PullRequestActivity(id: id, kind: .review, author: author, reviewState: review.state, body: review.body ?? "",
                                              date: review.submittedAt, byViewer: viewer.map { !$0.isEmpty && $0 == author } ?? false))
        }
        for comment in raw.comments ?? [] {
            guard let id = comment.id, comment.isMinimized != true else { continue }
            let author = comment.author?.login ?? ""
            result.append(PullRequestActivity(id: id, kind: .comment, author: author, body: comment.body ?? "", date: comment.createdAt,
                                              byViewer: comment.viewerDidAuthor == true || viewer.map { !$0.isEmpty && $0 == author } ?? false))
        }
        return result
    }
}

/// `gh` calls for pull requests. Read-only: `pr view`, `run view --log-failed` and `api user`.
public enum PullRequestLookup {
    public enum Outcome: Equatable, Sendable {
        case found(PullRequestStatus, activity: [PullRequestActivity]?)
        /// The branch has no pull request.
        case none
        /// Not a GitHub repository (no GitHub remote); worth asking again much later.
        case notGitHub
        /// `gh` is not signed in.
        case signedOut
        /// Network trouble, a timeout or an unexpected answer; ask again on the next occasion.
        case failed(String)
    }

    /// `gh pr view <selector>`: a branch name or a PR number. With `activity` the reviews and comments come in the
    /// same call.
    public static func view(_ selector: String, in folder: String, runner: GitRunner, activity: Bool = false,
                            viewer: String? = nil) async -> Outcome {
        guard !selector.isEmpty, !selector.hasPrefix("-") else { return .none }
        let fields = PullRequestStatus.fields + (activity ? "," + PullRequestActivity.fields : "")
        do {
            let result = try await runner.run(["pr", "view", selector, "--json", fields], in: folder)
            return classify(result, activity: activity, viewer: viewer)
        } catch {
            switch error {
            case .timedOut: return .failed("gh pr view timed out")
            case .launch(let message): return .failed(message)
            }
        }
    }

    static func classify(_ result: GitRunner.Result, activity: Bool, viewer: String?) -> Outcome {
        if result.succeeded {
            guard let status = PullRequestStatus.parse(result.output) else { return .failed("unexpected gh output") }
            return .found(status, activity: activity ? PullRequestActivity.parse(result.output, viewer: viewer) : nil)
        }
        let message = result.errors.lowercased()
        if message.contains("no pull requests found") { return .none }
        if message.contains("none of the git remotes") || message.contains("no git remotes") || message.contains("not a git repository") {
            return .notGitHub
        }
        if message.contains("gh auth login") || message.contains("not logged in") || message.contains("http 401")
            || message.contains("authentication") { return .signedOut }
        return .failed(result.errors.isEmpty ? "gh exited with status \(result.status)" : String(result.errors.prefix(300)))
    }

    /// The signed-in login (`gh api user`), to tell the user's own reviews from others'.
    public static func viewer(in folder: String, runner: GitRunner) async -> String? {
        guard let result = try? await runner.run(["api", "user", "--jq", ".login"], in: folder), result.succeeded else { return nil }
        let login = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }

    /// The failed steps' log of one Actions run (`gh run view <id> --log-failed`); nil when it is unavailable
    /// (expired logs, a run still in progress, no access).
    public static func failedLog(runID: String, in folder: String, runner: GitRunner) async -> String? {
        guard !runID.isEmpty, runID.allSatisfy(\.isNumber) else { return nil }
        guard let result = try? await runner.run(["run", "view", runID, "--log-failed"], in: folder), result.succeeded else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - gh JSON

struct RawPullRequest: Decodable {
    var number: Int?
    var title: String?
    var url: String?
    var state: String?
    var isDraft: Bool?
    var reviewDecision: String?
    var mergeable: String?
    var statusCheckRollup: [RawCheck]?
    var headRefName: String?
    var baseRefName: String?
}

/// A `statusCheckRollup` entry: `CheckRun` (status/conclusion) or `StatusContext` (state).
struct RawCheck: Decodable {
    var typename: String?
    var name: String?
    var workflowName: String?
    var status: String?
    var conclusion: String?
    var detailsUrl: String?
    var context: String?
    var state: String?
    var targetUrl: String?
    var startedAt: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", name, workflowName, status, conclusion, detailsUrl, context, state, targetUrl, startedAt
    }

    var check: PullRequestCheck? {
        if typename == "StatusContext" || (name == nil && context != nil) {
            guard let context, !context.isEmpty else { return nil }
            let outcome: PullRequestCheck.Outcome = switch state?.uppercased() {
            case "SUCCESS": .passed
            case "FAILURE", "ERROR": .failed
            case "PENDING", "EXPECTED": .pending
            default: .neutral
            }
            return PullRequestCheck(name: context, outcome: outcome, link: targetUrl.flatMap { $0.isEmpty ? nil : $0 })
        }
        guard let name, !name.isEmpty else { return nil }
        let outcome: PullRequestCheck.Outcome
        if let status, status.uppercased() != "COMPLETED" {
            outcome = .pending
        } else {
            outcome = switch conclusion?.uppercased() {
            case "SUCCESS": .passed
            case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": .failed
            // Cancelled, stale, skipped and neutral runs neither pass nor fail the PR.
            default: .neutral
            }
        }
        return PullRequestCheck(name: name, workflow: workflowName.flatMap { $0.isEmpty ? nil : $0 }, outcome: outcome,
                                link: detailsUrl.flatMap { $0.isEmpty ? nil : $0 })
    }
}

struct RawActivity: Decodable {
    struct Author: Decodable { var login: String? }
    struct Review: Decodable {
        var id: String?
        var author: Author?
        var body: String?
        var state: String?
        var submittedAt: String?
    }
    struct Comment: Decodable {
        var id: String?
        var author: Author?
        var body: String?
        var createdAt: String?
        var isMinimized: Bool?
        var viewerDidAuthor: Bool?
    }
    var reviews: [Review]?
    var comments: [Comment]?
}
