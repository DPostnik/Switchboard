import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ContextCore
@testable import ContextTranscript

@MainActor struct InterfaceZoomTests {
    private func defaults() -> UserDefaults {
        let name = "InterfaceZoomTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func missingOrInvalidPreferenceIsActualSize() {
        let store = defaults()
        #expect(InterfaceZoom(defaults: store).scale == 1)
        store.set(Double.nan, forKey: InterfaceZoom.preferenceKey)
        #expect(InterfaceZoom(defaults: store).scale == 1)
        store.set(-2, forKey: InterfaceZoom.preferenceKey)
        #expect(InterfaceZoom(defaults: store).scale == 1)
        store.set(9, forKey: InterfaceZoom.preferenceKey)
        #expect(InterfaceZoom(defaults: store).scale == 2)
    }

    @Test func stepsThroughTheRangeAndPersists() {
        let store = defaults()
        let zoom = InterfaceZoom(defaults: store)
        zoom.zoomIn(); #expect(zoom.scale == 1.1)
        zoom.zoomIn(); #expect(zoom.scale == 1.25)
        #expect(InterfaceZoom(defaults: store).scale == 1.25)
        #expect(zoom.scaled(14) == 18)
        for _ in 0..<20 { zoom.zoomIn() }
        #expect(zoom.scale == 2 && !zoom.canZoomIn)
        for _ in 0..<20 { zoom.zoomOut() }
        #expect(zoom.scale == 0.9 && !zoom.canZoomOut)
        zoom.reset()
        #expect(zoom.isActualSize && zoom.scaled(13) == 13 && zoom.percent == 100)
    }

    @Test func offStepValueMovesToTheNeighbouringSteps() {
        let store = defaults()
        store.set(1.3, forKey: InterfaceZoom.preferenceKey)
        let zoom = InterfaceZoom(defaults: store)
        zoom.zoomIn(); #expect(zoom.scale == 1.4)
        zoom.set(1.3); zoom.zoomOut(); #expect(zoom.scale == 1.25)
    }
}

@MainActor @Test func zoomedTextSizesMatchTheSystemStyleAtEachScale() {
    for scale: CGFloat in [1.25, 0.9, 1.25, 2] {
        for (style, appKit) in [(Font.TextStyle.body, NSFont.TextStyle.body), (.caption, .caption1), (.headline, .headline), (.title2, .title2)] {
            #expect(ZoomedTextSizes.size(style, scale: scale) == (NSFont.preferredFont(forTextStyle: appKit).pointSize * scale).rounded())
        }
    }
}
