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
/// Two forms switch it: the `use` function of `L10n`, and the language preference in the argument domain, which `L10n` reads once on
/// first use and SwiftUI's `@AppStorage` reads on every render.
/// A file may switch the language only when listed here with a reason and an isolation that excludes every other test.
private let languageSwitchAllowed: [String: String] = [
    // Opt-in render probes of whole app views (`DeskView`, `JobEditor`) that read the process language in many places.
    // Each is disabled unless its own environment variable is set, and is run alone with `--filter` (for the demo
    // capture: `scripts/capture-demo.sh`), so no other test shares the process.
    "ClaudeModelSelectorTests.swift": "opt-in render probe, run alone",
    "ProjectVisibilityTests.swift": "opt-in render probe, run alone",
    "JobSchedulerTests.swift": "opt-in render probe, run alone",
    "PublicDemoCaptureTests.swift": "opt-in demo capture, run alone by scripts/capture-demo.sh",
]

/// Whether a test source switches the process language, in either form. Split so that string literals in this file
/// do not match themselves.
func switchesProcessLanguage(_ source: String) -> Bool {
    let compact = source.filter { !$0.isWhitespace }
    return compact.contains("L10n" + ".use(")
        || (compact.contains("setVolatile" + "Domain(") && compact.contains("AppLanguage" + ".preferenceKey"))
        || compact.contains("\"interface" + "Language\"")
}

@Test func languageSwitchScannerFindsPlantedViolations() {
    let use = "L10n" + ".use(.english)"
    let spacedUse = "L10n" + " . use ( .russian )"
    let domain = "UserDefaults.standard.setVolatile" + "Domain([AppLanguage" + ".preferenceKey: \"en\"], forName: UserDefaults.argumentDomain)"
    let literal = "defaults.set(\"ru\", forKey: \"interface" + "Language\")"
    for planted in [use, spacedUse, domain, literal] { #expect(switchesProcessLanguage("func f() {\n    \(planted)\n}"), "\(planted)") }
    for clean in ["L10n.text(\"a\", \"b\", language: .english)", "let language = L10n.language", "SettingsProposalBoundarySummary(notes: [], language: .russian)"] {
        #expect(!switchesProcessLanguage(clean), "\(clean)")
    }
}

@Test func noTestSwitchesTheProcessLanguage() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var offenders: [String] = [], found: Set<String> = []
    var scanned = 0
    let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
        guard file.pathExtension == "swift" else { continue }
        scanned += 1
        guard switchesProcessLanguage(try String(contentsOf: file, encoding: .utf8)) else { continue }
        found.insert(file.lastPathComponent)
        if languageSwitchAllowed[file.lastPathComponent] == nil { offenders.append(file.lastPathComponent) }
    }
    #expect(scanned > 10)
    #expect(offenders.isEmpty, "Pass the language as a parameter instead of switching it for the process: \(offenders.sorted())")
    // A stale exception would silently allow a future switch in that file.
    #expect(Set(languageSwitchAllowed.keys).subtracting(found).isEmpty, "Remove exceptions that no longer switch: \(Set(languageSwitchAllowed.keys).subtracting(found).sorted())")
}
