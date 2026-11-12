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
    @Test func boundaryWarningsAcceptTheSplitViewMinimumHeight() {
        let previous = L10n.language
        defer { L10n.use(previous) }
        for language in [AppLanguage.russian, .english] {
            L10n.use(language)
            for effect in [SettingsProposalBoundaryNote.Effect.noExtraAccess(set: nil), .leavesBoundary(set: nil)] {
                let notes = [SettingsProposalBoundaryNote(projectID: UUID(), command: "scripts/chat-lookup.sh",
                                                         provider: "Claude", effect: effect)]
                let host = NSHostingView(rootView: ProposalWarningLayoutProbe {
                    SettingsProposalBoundarySummary(notes: notes)
                })
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height > 0)
            }
        }
    }
}
