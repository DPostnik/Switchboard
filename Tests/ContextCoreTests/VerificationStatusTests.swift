import Foundation
import Testing
import ContextCore

@Test func verificationProjectionRejectsUnknownSchemaAndPreservesTaskData() throws {
    let data = Data(#"{"schemaVersion":1,"tasks":[{"id":"task-a","title":"User title","status":"awaiting_live","blocker":"fixture"}]}"#.utf8)
    let status = try VerificationStatus.decode(data)
    #expect(status.tasks.first?.title == "User title")
    #expect(status.tasks.first?.blocker == "fixture")
    #expect(throws: VerificationStatus.StatusError.self) {
        try VerificationStatus.decode(Data(#"{"schemaVersion":2,"tasks":[]}"#.utf8))
    }
    #expect(VerificationStatus.title("awaiting_live", language: .english) == "App verification needed")
    #expect(VerificationStatus.title("awaiting_live", language: .russian) == "Нужна проверка в приложении")
    #expect(VerificationStatus.title("future", language: .english) == "Unknown status")
}

@Test func verificationProjectionBoundsUntrustedDurations() throws {
    let status = try VerificationStatus.decode(Data(#"{"schemaVersion":1,"tasks":[],"batches":[{"id":"extreme","status":"running","created_at":-1e308,"started_at":1e308,"finished_at":1e308}]}"#.utf8))
    #expect(status.batches?.first?.waitingSeconds == 0)
    #expect(status.batches?.first?.runningSeconds == 0)
}
