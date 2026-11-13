import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDesk

/// The sub-agent bar's chips hug their titles: a short name ("test 1") must not stretch to the old 180 pt maximum when
/// the bar offers more room (seen 2026-11-13 in a Codex chat with two sub-agents).
@Suite(.serialized) @MainActor
struct SubagentChipLayoutTests {
    private func width(_ title: String) -> CGFloat {
        let controller = NSHostingController(rootView: SubagentChip(title: title, icon: Image(systemName: "checkmark.circle.fill")))
        return controller.sizeThatFits(in: CGSize(width: 900, height: 40)).width
    }

    @Test func shortTitlesStayNarrowAndLongOnesAreCut() {
        let short = width("test 1")
        let long = width(String(repeating: "Review the routing layer ", count: 8))
        #expect(short > 20 && short < 110, "short chip width \(short)")
        #expect(long > short && long < 260, "long chip width \(long)")
    }
}
