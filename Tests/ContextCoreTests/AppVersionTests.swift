import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Suite struct AppVersionTests {
    @Test func readsTheBundleIdentityAndTheBuildRecord() {
        let app = AppVersion(info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "263"],
                             record: ["commit": "47b3984", "dirty": false, "builtAt": "2026-10-31T14:28:20.323830+00:00"])
        #expect(app.label == "1.0.0 (263)")
        #expect(app.commit == "47b3984")
        #expect(!app.dirty)
        #expect(app.builtAt == Date(timeIntervalSince1970: 1_793_456_900))
        #expect(app.report(language: .english).hasPrefix("Switchboard 1.0.0 (263), 47b3984, Oct 31, 2026"))
        // ICU separates "2026" and "г." with a narrow no-break space; compare the stable parts only.
        #expect(app.report(language: .russian).hasPrefix("Switchboard 1.0.0 (263), 47b3984, 31 окт"))
        #expect(app.report(language: .russian).contains("2026"))
    }

    @Test func fallsBackWithoutARecordAndMarksDirtyBuilds() {
        let bare = AppVersion(info: [:], record: [:])
        #expect(bare.label == "dev (0)")
        #expect(bare.commit == nil)
        #expect(bare.builtAt == nil)
        #expect(bare.report(language: .english) == "Switchboard dev (0)")
        let dirty = AppVersion(info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "264"],
                               record: ["commit": "abc1234", "dirty": true, "builtAt": "not a date"])
        #expect(dirty.builtAt == nil)
        #expect(dirty.report(language: .english) == "Switchboard 1.0.0 (264), abc1234+")
    }

    @Test func theRunningBundleReportsItsVersion() {
        // Under the test runner the bundle has no Info.plist of its own; the fallbacks must hold.
        let app = AppVersion(bundle: .main)
        #expect(!app.version.isEmpty)
        #expect(!app.build.isEmpty)
    }
}
