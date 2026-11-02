import Foundation
import Testing
@testable import ContextDesk

@Test func nightlyReportAcceptsOnlyKnownResultsIncludingCompatibility() throws {
    for result in ["failed", "flaky", "compat"] {
        let content = try #require(NightlyTestsReport.content(result: result, summary: String(repeating: "x", count: 400)))
        #expect(!content.title.isEmpty)
        #expect(content.body.count == 300)
        #expect(NightlyTestsReport.isReport(content.userInfo))
    }
    #expect(Set(["failed", "flaky", "compat"].compactMap { NightlyTestsReport.content(result: $0, summary: "s")?.title }).count == 3)
    #expect(NightlyTestsReport.content(result: "passed", summary: "s") == nil)
}
