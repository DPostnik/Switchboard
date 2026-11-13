import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDesk

/// Exercise SwiftUI's minimum-size proposal, which a normal wide card snapshot misses.
private struct ProposalWarningLayoutProbe: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let minimum = subviews[0].sizeThatFits(.zero)
        #expect(minimum.height < 100, "The warning must not impose a tall minimum on both split-view columns")
        let readable = subviews[0].sizeThatFits(ProposedViewSize(width: 600, height: nil))
        #expect(readable.height > 0)
        #expect(readable.height < 200)
        return readable
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

@Suite(.serialized) @MainActor
struct SettingsProposalLayoutTests {
    // The language is passed to the view, never switched for the process: tests run in parallel in one process and
    // other suites (the Claude adapter's localized launch arguments) read the process language at the same time.
    @Test func boundaryWarningsAcceptTheSplitViewMinimumHeight() {
        for language in [AppLanguage.russian, .english] {
            for effect in [SettingsProposalBoundaryNote.Effect.noExtraAccess(set: nil), .leavesBoundary(set: nil)] {
                let notes = [SettingsProposalBoundaryNote(projectID: UUID(), command: "scripts/chat-lookup.sh",
                                                         provider: "Claude", effect: effect)]
                let text = SettingsProposalBoundarySummary.text(notes, language: language) ?? ""
                #expect(text.hasPrefix(language == .russian ? "Внимание:" : "Warning:"))
                let host = NSHostingView(rootView: ProposalWarningLayoutProbe {
                    SettingsProposalBoundarySummary(notes: notes, language: language)
                })
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height > 0)
            }
        }
    }
}

/// Swift Testing runs the whole test target in parallel in one process, and the app language is process-global
/// (`L10n`). A test that switches it changes the strings other tests build at the same moment, for example the Claude
/// adapter's localized launch arguments, which then no longer match a warm process. Pass `language:` instead.
/// A file may switch the language only when listed here with a reason and an isolation that excludes every other test.
@Test func noTestSwitchesTheProcessLanguage() throws {
    let allowed: Set<String> = []
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let needle = "L10n" + ".use("
    var offenders: [String] = []
    var scanned = 0
    let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
        guard file.pathExtension == "swift" else { continue }
        scanned += 1
        let source = try String(contentsOf: file, encoding: .utf8)
        if source.contains(needle), !allowed.contains(file.lastPathComponent) { offenders.append(file.lastPathComponent) }
    }
    #expect(scanned > 10)
    #expect(offenders.isEmpty, "Pass the language as a parameter instead of switching it for the process: \(offenders.sorted())")
}
