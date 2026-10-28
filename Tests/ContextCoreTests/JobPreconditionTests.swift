import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

@Test func preconditionExitCodesDecideTheRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let label = "precondition-test-" + UUID().uuidString.lowercased()
    // Runs in the project folder; its output is kept for the prompt.
    let found = await JobPrecondition(command: "echo found; pwd").evaluate(in: root.path, label: label)
    guard case .run(let listing) = found else { Issue.record("Exit 0 must run: \(found)"); return }
    #expect(listing.hasPrefix("found\n") && listing.hasSuffix("/" + root.lastPathComponent))
    #expect(await JobPrecondition(command: "exit 1").evaluate(in: root.path, label: label) == .skip)
    guard case .broken(let reason) = await JobPrecondition(command: "echo bad >&2; exit 7").evaluate(in: root.path, label: label) else {
        Issue.record("Exit 7 must block the run"); return
    }
    #expect(reason.contains("7") && reason.contains("bad"))
    let started = Date()
    guard case .broken = await JobPrecondition(command: "sleep 30", timeout: 1).evaluate(in: root.path, label: label) else {
        Issue.record("A timeout must block the run"); return
    }
    #expect(Date().timeIntervalSince(started) < 10)
    let long = await JobPrecondition(command: "head -c 9000 /dev/zero | tr '\\0' x").evaluate(in: root.path, label: label)
    guard case .run(let output) = long else { Issue.record("Long output must still run"); return }
    #expect(output.count == JobPrecondition.outputLimit + 1 && output.hasSuffix("…"))
    #expect(JobPrecondition(command: "  ").isEmpty && !JobPrecondition(command: "true").isEmpty)
}

@Test func preconditionFindingsAreAddedToThePromptAsData() {
    #expect(JobPrecondition.prompt("Check mail", output: "  \n") == "Check mail")
    let prompt = JobPrecondition.prompt("Check mail", output: "2 new letters\n")
    #expect(prompt.hasPrefix("Check mail\n\n") && prompt.contains("```\n2 new letters\n```"))
    // Saved jobs from before the field decode without it.
    var job = ManagedJob(); job.name = "n"
    var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
    object.removeValue(forKey: "precondition")
    #expect(try! JSONDecoder().decode(ManagedJob.self, from: JSONSerialization.data(withJSONObject: object)).precondition == nil)
}

private actor RecordingExecutorFixture: AgentScheduledExecutor {
    var prompts: [String] = []
    func descriptor() -> AgentResult<AgentDescriptor> {
        .success(.init(context: .init(connection: .init(agent: .claudeCode, id: UUID()), accountRevision: UUID()),
            identityMode: .externalCLI, capabilities: [.scheduledExecution], permissions: .externalPolicyOnly, routes: [.externalConfiguration]))
    }
    func execute(_ request: AgentExecutionRequest, willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentScheduledResult> {
        prompts.append(request.prompt)
        return .success(.finished(.completed, output: "done"))
    }
    func stop() {}
}

@Test @MainActor func preconditionSkipsRunsOrBlocksBeforeTheAgentStarts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let fixture = RecordingExecutorFixture()
    model.jobExecutorFactories[.claude] = { _, _, _, _ in fixture }
    let project = Project(path: root.path); model.state.projects = [project]; model.schedulerReady = true
    func run(_ command: String) async throws -> JobRun {
        var job = ManagedJob(); job.name = "Mail"; job.prompt = "Check mail"; job.projectID = project.id; job.engine = .claude
        job.precondition = JobPrecondition(command: command)
        #expect(await model.saveJob(job))
        await model.launchJob(job.id)
        for task in Array(model.jobTasks.values) { await task.value }
        return try #require(model.jobLedger.runs.first { $0.jobID == job.id })
    }
    let skipped = try await run("exit 1")
    let afterSkip = await fixture.prompts
    #expect(skipped.status == .skipped && afterSkip.isEmpty)
    #expect(!model.attention.open.contains { $0.runID == skipped.id })
    let blocked = try await run("exit 4")
    let afterBlock = await fixture.prompts
    #expect(blocked.status == .blocked && afterBlock.isEmpty)
    #expect(model.attention.open.contains { $0.runID == blocked.id })
    let ran = try await run("echo 2 new letters")
    #expect(ran.status == .completed)
    let prompts = await fixture.prompts
    #expect(prompts.count == 1 && prompts[0].hasPrefix("Check mail") && prompts[0].contains("2 new letters"))
}
