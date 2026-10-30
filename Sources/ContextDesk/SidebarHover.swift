import ContextTranscript
import Observation
import SwiftUI

/// Hovered sidebar rows. Scrolling moves rows under a still pointer, so hover changes many times a second;
/// only `SidebarRowBackground` reads it, which keeps those changes from re-rendering the whole window.
@MainActor @Observable final class SidebarHover {
    private(set) var rows: Set<String> = []

    func set(_ rowID: String, inside: Bool) {
        guard rows.contains(rowID) != inside else { return }
        if inside { rows.insert(rowID) } else { rows.remove(rowID) }
    }

    /// The row itself or its trailing tools (`rowID#tools`) is under the pointer.
    func isHovered(_ rowID: String) -> Bool { rows.contains(rowID) || rows.contains(rowID + "#tools") }
}

/// Row fill: a non-clear `base` (selection, open menu) wins; otherwise the hover tint while the pointer is over the row.
struct SidebarRowBackground: View {
    let hover: SidebarHover
    let rowID: String
    let base: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(base == .clear && hover.isHovered(rowID) ? DeskPalette.rowHover : base)
    }
}
