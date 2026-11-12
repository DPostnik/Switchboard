import Foundation
import Testing
@testable import ContextCore

@Test func attentionMarkersAreExplicitLinesOnly() {
    let report = """
    ## Итог
    - **Главный blocker:** браузер не подключился.
    BLOCKER: LinkedIn не показывает ID вакансий — нужно решить, как их получать.
    - **BLOCKER:** Ответь на Q-0110, чтобы снять lock подготовки.
    > BLOCKER: ответь на q-0110,   чтобы снять lock подготовки.
    blocker: lowercase is prose, not a marker
    ```
    BLOCKER: inside a code fence
    ```
    BLOCKER:
    """
    #expect(AttentionMarkers.blockers(in: report) == [
        "LinkedIn не показывает ID вакансий — нужно решить, как их получать.",
        "Ответь на Q-0110, чтобы снять lock подготовки."
    ])
    let many = (0..<30).map { "BLOCKER: item \($0) " + String(repeating: "x", count: 600) }.joined(separator: "\n")
    let parsed = AttentionMarkers.blockers(in: many)
    #expect(parsed.count == AttentionMarkers.maxPerRun && parsed.allSatisfy { $0.count == AttentionMarkers.maxLength + 1 })
}

@Test func attentionInstructionsExistInBothLanguages() {
    let ru = AttentionMarkers.instructions(language: .russian), en = AttentionMarkers.instructions(language: .english)
    #expect(ru != en && ru.contains("BLOCKER:") && en.contains("BLOCKER:"))
    #expect(ru.contains("Важное") && en.contains("Important"))
}

@Test func attentionLedgerDeduplicatesAndKeepsBlockersUntilResolved() {
    var ledger = AttentionLedger()
    let job = UUID(), other = UUID()
    let start = Date(timeIntervalSince1970: 1_000)
    func source(_ id: UUID = job) -> AttentionSource { AttentionSource(jobID: id, jobName: "Daily", runID: UUID(), threadID: "chat") }

    var created = ledger.record(source(), status: .completed, output: "BLOCKER: Need a token", now: start)
    #expect(created.count == 1 && ledger.open.count == 1)
    // The same blocker on the next day updates the open item instead of duplicating it.
    created = ledger.record(source(), status: .completed, output: "BLOCKER:  need a   TOKEN", now: start + 86_400)
    #expect(created.isEmpty && ledger.open.count == 1)
    #expect(ledger.open[0].occurrences == 2 && ledger.open[0].lastSeen == start + 86_400 && ledger.open[0].created == start)
    // Another task reporting the same text is a separate item.
    created = ledger.record(source(other), status: .completed, output: "BLOCKER: Need a token", now: start)
    #expect(created.count == 1)

    // Run problems are recorded per task and status, and a later successful run clears them.
    created = ledger.record(source(), status: .failed, output: "Process exited", now: start + 2)
    #expect(created.map(\.kind) == [.runProblem] && created[0].text == JobRunStatus.failed.title && created[0].detail == "Process exited")
    created = ledger.record(source(), status: .interrupted, output: "", now: start + 3)
    #expect(created.isEmpty)
    ledger.record(source(), status: .completed, output: "", now: start + 4)
    let problem = ledger.items.first { $0.kind == .runProblem }
    #expect(problem?.isOpen == false && problem?.resolvedAutomatically == true)
    #expect(ledger.open.filter { $0.jobID == job }.map(\.kind) == [.blocker])

    // A resolved blocker that is reported again opens a new item; reopening the old one is then refused.
    let blocker = ledger.open.first { $0.jobID == job }!.id
    let resolved = ledger.resolve(blocker, now: start + 5), repeated = ledger.resolve(blocker)
    #expect(resolved && !repeated)
    created = ledger.record(source(), status: .completed, output: "BLOCKER: Need a token", now: start + 6)
    #expect(created.count == 1)
    let reopened = ledger.reopen(blocker)
    #expect(!reopened)
    ledger.clearResolved()
    #expect(ledger.items.allSatisfy(\.isOpen) && ledger.open.count == 2)
}

@Test func attentionLedgerBoundsResolvedHistory() {
    var ledger = AttentionLedger()
    for index in 0..<(AttentionLedger.resolvedLimit + 20) {
        let item = ledger.record(AttentionSource(jobID: UUID(), jobName: "J", runID: UUID(), threadID: nil),
                                 status: .completed, output: "BLOCKER: \(index)", now: Date(timeIntervalSince1970: Double(index)))
        ledger.resolve(item[0].id, now: Date(timeIntervalSince1970: Double(index)))
    }
    ledger.record(AttentionSource(jobID: UUID(), jobName: "J", runID: UUID(), threadID: nil), status: .completed, output: "BLOCKER: open")
    #expect(ledger.resolved.count == AttentionLedger.resolvedLimit && ledger.open.count == 1)
    #expect(ledger.resolved.last?.text == "20")
}

@Test func attentionStorePersistsPrivatelyAndRejectsUnknownFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("attention.json")
    let store = AttentionStore(file: file)
    #expect(try await store.load().items.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let (_, created) = try await store.update {
        $0.record(AttentionSource(jobID: UUID(), jobName: "J", runID: UUID(), threadID: nil), status: .blocked, output: "denied")
    }
    #expect(created.count == 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try await AttentionStore(file: file).load().open.map(\.id) == created.map(\.id))

    try Data(#"{"version":2,"items":[]}"#.utf8).write(to: file)
    let unknown = AttentionStore(file: file)
    await #expect(throws: (any Error).self) { try await unknown.load() }
    let clear: @Sendable (inout AttentionLedger) -> Void = { $0.clearResolved() }
    await #expect(throws: (any Error).self) { try await unknown.update(clear) }
    #expect(try String(contentsOf: file, encoding: .utf8) == #"{"version":2,"items":[]}"#)
}

@Test func quotaAttentionReconcilesOncePerRunAndAutomaticallyClears() throws {
    var ledger = AttentionLedger()
    let source = AttentionSource(jobID: UUID(), jobName: "Daily", runID: UUID(), threadID: nil)
    let created = ledger.reconcileQuotaWaits([(source, "Check after 13:01")])
    #expect(created.count == 1 && created[0].kind == .quotaWait && created[0].threadID == nil)
    #expect(created[0].jobID == source.jobID)
    // Relaunch and polling update the detail without issuing another notification.
    ledger = try JSONDecoder().decode(AttentionLedger.self, from: JSONEncoder().encode(ledger))
    let result1 = ledger.reconcileQuotaWaits([(source, "Check after 14:01")])
    #expect(result1.isEmpty)
    #expect(ledger.open.first?.detail == "Check after 14:01")
    #expect(ledger.open.first?.occurrences == 1)
    _ = ledger.reconcileQuotaWaits([])
    #expect(ledger.open.isEmpty && ledger.resolved.first?.resolvedAutomatically == true)
    let next = AttentionSource(jobID: source.jobID, jobName: source.jobName, runID: UUID(), threadID: "chat")
    let result2 = ledger.reconcileQuotaWaits([(next, "Waiting")])
    #expect(result2.count == 1)
}

@Test func manuallyResolvedQuotaAttentionDoesNotNotifyOnPoll() {
    var ledger = AttentionLedger()
    let source = AttentionSource(jobID: UUID(), jobName: "Daily", runID: UUID(), threadID: nil)
    let item = ledger.reconcileQuotaWaits([(source, "Waiting")])[0]
    let result3 = ledger.resolve(item.id)
    #expect(result3)
    let result4 = ledger.reconcileQuotaWaits([(source, "Waiting")])
    #expect(result4.isEmpty)
    #expect(ledger.open.isEmpty)
    ledger.clearResolved()
    let result5 = ledger.reconcileQuotaWaits([(source, "Waiting")])
    #expect(result5.isEmpty)
}
