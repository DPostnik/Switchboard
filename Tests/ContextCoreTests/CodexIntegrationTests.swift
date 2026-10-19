@_spi(NativeProtocol) @testable import CodexAdapter
import Foundation
import Testing
import ContextCore
import AgentContract
@testable import ContextDesk

private func contractFixture(version: String = "0.159.0", disconnect: Bool = false, changeDuring: String = "") throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("engine.py")
    let script = #"""
    #!\#(fixturePython)
    import json,sys
    calls=[]
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; p=m.get('params',{}); result={}
        if method=='initialize': result={'userAgent':'codex/VERSION fixture'}
        if method=='thread/start': result={'thread':{'id':'session'}}
        if method=='turn/start':
            if DISCONNECT: sys.exit(0)
            result={'turn':{'id':'turn'}}
        if method=='account/read': result={'account':{'planType':'fixture'}}
        if method=='model/list': result={'data':[{'model':'fixture','isDefault':True}]}
        if method in ['test/change','account/logout']:
            print(json.dumps({'method':'account/updated','params':{}}),flush=True)
        if method=='CHANGE_DURING' and method not in calls:
            print(json.dumps({'method':'account/updated','params':{}}),flush=True)
        if method=='test/calls': result=calls
        else: calls.append(method)
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.replacingOccurrences(of: "VERSION", with: version).replacingOccurrences(of: "DISCONNECT", with: disconnect ? "True" : "False").replacingOccurrences(of: "CHANGE_DURING", with: changeDuring)
    try Data(script.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    return (root, executable)
}

@Test(arguments: ["999.0", "0.159.1", "0.159.0-alpha.1", "0.159.00", "999.0 metadata/0.159.0"])
func contractRuntimeRejectsUnverifiedVersionsBeforeSessionDispatch(version: String) async throws {
    let (root, executable) = try contractFixture(version: version)
    defer { try? FileManager.default.removeItem(at: root) }
    let integration: any AgentIntegration = CodexIntegration()
    if case .rejected(.incompatibleContract) = await integration.connect(.init(executable: executable, home: root)) {} else { Issue.record("Unverified version accepted") }
    if case .unavailable = await integration.descriptor() {} else { Issue.record("Rejected connection left usable") }
}

@Test func contractRuntimeBindsPreparedWorkToAccountAndChecksTransportAtWrite() async throws {
    let (root, executable) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection()
    let integration = CodexIntegration(client: CodexClient(transport: wire))
    let app = AgentClient(integration: integration)
    let descriptor = try await app.start(.init(executable: executable, home: root))
    #expect(descriptor.capabilities.contains(.isolatedGeneration))
    let session = try await app.createSession(projectPath: root.path, access: .standard, model: "fixture", route: .direct)
    _ = try await wire.request("test/change")
    let changed = try await app.descriptor()
    #expect(changed.context != descriptor.context)
    await #expect(throws: AgentOperationFailure.self) {
        _ = try await app.createSession(projectPath: root.path, access: .standard, model: "fixture", route: .direct, context: descriptor.context)
    }
    await #expect(throws: AgentOperationFailure.self) {
        try await app.send("Do not send stale work", to: session, projectPath: root.path, access: .standard, model: "fixture", effort: "")
    }
    await #expect(throws: CodexDispatchRejection.self) {
        try await CodexDispatchContext.$epoch.withValue(descriptor.context.accountRevision) {
            _ = try await wire.request("turn/start")
        }
    }
    #expect(try await wire.request("test/calls").array.compactMap(\.string).filter { $0 == "turn/start" }.isEmpty)
    try await app.resume(session, projectPath: root.path, access: .standard, route: .direct)
    #expect(try await app.send("Explicit new work", to: session, projectPath: root.path, access: .standard, model: "fixture", effort: "") == "turn")
    // A confirmed logout legitimately changes the account while its RPC is in flight.
    if case .complete = try await integration.authenticate(.signOut).value() {} else { Issue.record("Confirmed logout was rejected") }
    #expect(try await app.descriptor().context != changed.context)
    await app.stop()
}

@Test func contractRuntimeRejectsRoutesPermissionsAndReplaysBeforeSending() async throws {
    let (root, executable) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection()
    let adapter: any AgentIntegration = CodexIntegration(client: CodexClient(transport: wire))
    let descriptor = try await adapter.connect(.init(executable: executable, home: root)).value()
    func request(route: AgentRoute = .direct, network: Bool = false) -> AgentExecutionRequest {
        .init(conversation: ConversationID(), session: .init(connection: .originalCodex, nativeID: "session"), kind: .scheduled,
            prompt: "fixture", projectPath: root.path, permissions: .workspaceWrite(root: root.path, network: network, approval: .ask),
            model: .init(context: descriptor.context, model: "fixture"), route: route)
    }
    if case .rejected(.routeUnavailable) = await adapter.submit(request(route: .optimizer(id: "missing"))) {} else { Issue.record("Unavailable route accepted") }
    let prompting = AgentExecutionRequest(conversation: ConversationID(), session: .init(connection: .originalCodex, nativeID: "session"), kind: .scheduled,
        prompt: "fixture", projectPath: root.path, permissions: .unrestricted(approval: .ask), model: .init(context: descriptor.context, model: "fixture"), route: .direct)
    if case .rejected(.unsupportedPermissions) = await adapter.submit(prompting) {} else { Issue.record("Restrictions weakened") }
    #expect(try await wire.request("test/calls").array.compactMap(\.string) == ["initialize"])
    let work = request()
    _ = try await adapter.prepare(work).value()
    _ = try await adapter.submit(work).value()
    if case .rejected(.unknownRequest) = await adapter.submit(work) {} else { Issue.record("Duplicate submission accepted") }
    #expect(try await wire.request("test/calls").array.compactMap(\.string).filter { $0 == "turn/start" }.count == 1)
    await adapter.disconnect()
}

@Test func contractRuntimeClassifiesLostAcknowledgementAsUncertain() async throws {
    let (root, executable) = try contractFixture(disconnect: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter: any AgentIntegration = CodexIntegration()
    let descriptor = try await adapter.connect(.init(executable: executable, home: root)).value()
    let work = AgentExecutionRequest(conversation: ConversationID(), session: .init(connection: .originalCodex, nativeID: "session"), kind: .interactive,
        prompt: "fixture", projectPath: root.path, permissions: .unrestricted(approval: .never),
        model: .init(context: descriptor.context, model: "fixture"), route: .direct)
    _ = try await adapter.prepare(work).value()
    if case .failed(let failure) = await adapter.submit(work) { #expect(failure.delivery == .uncertain) }
    else { Issue.record("Lost acknowledgement was not classified uncertain") }
    await adapter.disconnect()
}

@Test func contractCancellationBeforeGenerationDoesNotLaunchOrClaimWork() async throws {
    let (root, executable) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection()
    let adapter: any AgentIntegration = CodexIntegration(client: CodexClient(transport: wire))
    let descriptor = try await adapter.connect(.init(executable: executable, home: root)).value()
    let request = AgentGenerationRequest(source: .init(connection: .originalCodex, nativeID: "session"),
        recipe: .chatTitleV1, historicalInput: "Fixture", model: .init(context: descriptor.context, model: "fixture"), route: .direct, language: "en")
    await adapter.cancelGeneration(request.id)
    let result = await adapter.generate(request, environment: .init(executable: executable, home: root, workspace: root.appendingPathComponent("unused"))) {
        Issue.record("Cancelled generation reached its durable dispatch claim")
    }
    if case .failed(let failure) = result { #expect(failure.delivery == .notSent) }
    else { Issue.record("Cancelled generation was not stopped before dispatch") }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unused").path))
    #expect(try await wire.request("test/calls").array.compactMap(\.string) == ["initialize"])
    await adapter.disconnect()
}

@Test @MainActor func startupAccountUpdateDiscardsObsoleteMetadataWithoutBannerOrReplay() async throws {
    let (root, executable) = try contractFixture(changeDuring: "account/read")
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection()
    let adapter = CodexIntegration(client: CodexClient(transport: wire))
    _ = try await adapter.connect(.init(executable: executable, home: root)).value()
    let model = DeskModel(connection: adapter, store: AppStore(file: root.appendingPathComponent("state.sqlite")))
    model.error = "Existing unrelated error"
    await model.refreshAccount()
    #expect(model.error == "Existing unrelated error")
    #expect(!model.authenticated)
    #expect(try await wire.request("test/calls").array.compactMap(\.string).filter { $0 == "account/read" }.count == 1)
    model.error = nil
    await model.refreshAccount()
    #expect(model.authenticated)
    #expect(model.models.contains { $0.id == "fixture" })
    #expect(model.error == nil)
    await adapter.disconnect()
}

@Test(arguments: ["model/list", "account/rateLimits/read"])
func obsoleteMetadataIsTypedRejection(method: String) async throws {
    let (root, executable) = try contractFixture(changeDuring: method)
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection()
    let adapter = CodexIntegration(client: CodexClient(transport: wire))
    _ = try await adapter.connect(.init(executable: executable, home: root)).value()
    if method == "model/list" {
        if case .rejected(.staleContext) = await adapter.models() {} else { Issue.record("Obsolete models were not rejected") }
    } else {
        if case .rejected(.staleContext) = await adapter.limits() {} else { Issue.record("Obsolete limits were not rejected") }
    }
    #expect(try await wire.request("test/calls").array.compactMap(\.string).filter { $0 == method }.count == 1)
    await adapter.disconnect()
}

@Test(arguments: ["0.158.0-alpha.2.1", "0.159.0"])
func contractRuntimeAcceptsVerifiedVersions(version: String) async throws {
    let (root, executable) = try contractFixture(version: version)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AgentClient(integration: CodexIntegration())
    _ = try await app.start(.init(executable: executable, home: root))
    #expect(try await app.account().authenticated)
    #expect(try await app.models().contains { $0.id == "fixture" })
    await app.stop()
}
