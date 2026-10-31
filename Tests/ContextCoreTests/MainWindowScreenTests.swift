import Foundation
import Testing
@testable import ContextDesk

@Suite struct MainWindowScreenTests {
    // The built-in display's visible area (menu bar excluded), as macOS reports it.
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 949)

    @Test func windowOnAnotherDisplayKeepsItsSizeAndIsCentered() {
        let external = CGRect(x: 1512, y: 300, width: 1120, height: 760)
        let placed = MainWindowScreen.placement(window: external, visible: builtIn)
        #expect(placed.size == external.size)
        // (949 - 760) / 2 = 94.5 rounds to 95.
        #expect(placed == CGRect(x: 196, y: 95, width: 1120, height: 760))
        #expect(builtIn.contains(placed))
    }

    @Test func oversizedWindowShrinksToTheVisibleArea() {
        let huge = CGRect(x: 1512, y: 0, width: 3000, height: 1600)
        let placed = MainWindowScreen.placement(window: huge, visible: builtIn)
        #expect(placed == builtIn)
    }

    @Test func fullDisplayWindowStaysFull() {
        let full = CGRect(x: 2000, y: 100, width: 1512, height: 949)
        #expect(MainWindowScreen.placement(window: full, visible: builtIn) == builtIn)
    }

    @Test func visibleAreaWithOffsetOriginIsRespected() {
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let placed = MainWindowScreen.placement(window: CGRect(x: 0, y: 0, width: 400, height: 300), visible: visible)
        #expect(placed == CGRect(x: 400, y: 300, width: 400, height: 300))
    }

    @Test func preferenceDefaultsToOn() {
        let key = MainWindowScreen.preferenceKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(MainWindowScreen.enabled)
        UserDefaults.standard.set(false, forKey: key)
        #expect(!MainWindowScreen.enabled)
        UserDefaults.standard.set(true, forKey: key)
        #expect(MainWindowScreen.enabled)
    }
}
