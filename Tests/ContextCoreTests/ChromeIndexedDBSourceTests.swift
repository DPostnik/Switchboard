import Foundation
import Testing
@testable import ContextCore

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSourceProfile(store name: String?, withBlob: Bool) throws -> URL {
    let root = tempRoot()
    try Data(#"{"profile":{"info_cache":{"Default":{"name":"Fixture"}}}}"#.utf8).write(to: root.appendingPathComponent("Local State"))
    let idb = root.appendingPathComponent("Default/IndexedDB")
    try FileManager.default.createDirectory(at: idb, withIntermediateDirectories: true)
    if let name {
        let leveldb = idb.appendingPathComponent(name + ".indexeddb.leveldb")
        try FileManager.default.createDirectory(at: leveldb, withIntermediateDirectories: true)
        try Data("01".utf8).write(to: leveldb.appendingPathComponent("CURRENT"))
        try Data(repeating: 7, count: 2048).write(to: leveldb.appendingPathComponent("000003.log"))
        if withBlob {
            let blob = idb.appendingPathComponent(name + ".indexeddb.blob").appendingPathComponent("1")
            try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)
            try Data(repeating: 9, count: 16).write(to: blob.appendingPathComponent("00"))
        }
    }
    return root
}

private func makeEnvironment() throws -> (browserRoot: URL, environment: URL) {
    let browserRoot = tempRoot()
    let env = browserRoot.appendingPathComponent("environments").appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
    return (browserRoot, env)
}

@Test func indexedDBCanonicalNameAndComponentValidation() {
    #expect(ChromeIndexedDBSource.canonicalName(scheme: "https", host: "example.com") == "https_example.com_0.indexeddb.leveldb")
    #expect(ChromeIndexedDBSource.validOriginComponent("example.com"))
    #expect(!ChromeIndexedDBSource.validOriginComponent("bad/host"))
    #expect(!ChromeIndexedDBSource.validOriginComponent(""))
}

@Test func indexedDBInstallClonesStoreAndBlob() throws {
    let source = try makeSourceProfile(store: "https_example.test_0", withBlob: true)
    defer { try? FileManager.default.removeItem(at: source) }
    let (browserRoot, env) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: browserRoot) }
    let result = try ChromeIndexedDBSource.install(profile: "Default", root: source, scheme: "https", host: "example.test",
                                                   environment: env, browserRoot: browserRoot, sourceIsRunning: { false })
    let unwrapped = try #require(result)
    #expect(unwrapped.storeName == "https_example.test_0.indexeddb.leveldb")
    #expect(unwrapped.blobCopied)
    #expect(unwrapped.copiedBytes == 2048 + 2 + 16)
    let dest = env.appendingPathComponent("testing-profile/Default/IndexedDB")
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("https_example.test_0.indexeddb.leveldb/CURRENT").path))
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("https_example.test_0.indexeddb.leveldb/000003.log").path))
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("https_example.test_0.indexeddb.blob/1/00").path))
}

@Test func indexedDBInstallMatchesNonCanonicalIndexAndReplaces() throws {
    let source = try makeSourceProfile(store: "https_example.test_3", withBlob: false)
    defer { try? FileManager.default.removeItem(at: source) }
    let (browserRoot, env) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: browserRoot) }
    // Pre-existing stale store of the same name must be replaced, not merged.
    let dest = env.appendingPathComponent("testing-profile/Default/IndexedDB/https_example.test_3.indexeddb.leveldb")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: dest.appendingPathComponent("STALE"))
    let result = try ChromeIndexedDBSource.install(profile: "Default", root: source, scheme: "https", host: "example.test",
                                                   environment: env, browserRoot: browserRoot, sourceIsRunning: { false })
    #expect(result?.storeName == "https_example.test_3.indexeddb.leveldb")
    #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("STALE").path))
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("CURRENT").path))
}

@Test func indexedDBInstallReturnsNilWithoutStoreAndRefusesRunningSource() throws {
    let empty = try makeSourceProfile(store: nil, withBlob: false)
    defer { try? FileManager.default.removeItem(at: empty) }
    let (browserRoot, env) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: browserRoot) }
    #expect(try ChromeIndexedDBSource.install(profile: "Default", root: empty, scheme: "https", host: "example.test",
                                              environment: env, browserRoot: browserRoot, sourceIsRunning: { false }) == nil)
    let source = try makeSourceProfile(store: "https_example.test_0", withBlob: false)
    defer { try? FileManager.default.removeItem(at: source) }
    #expect(throws: ChromeCookieError.sourceRunning) {
        try ChromeIndexedDBSource.install(profile: "Default", root: source, scheme: "https", host: "example.test",
                                          environment: env, browserRoot: browserRoot, sourceIsRunning: { true })
    }
}
