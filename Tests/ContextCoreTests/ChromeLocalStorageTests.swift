import Foundation
import Testing
@testable import ContextCore

/// Builds a LevelDB Local Storage data key: "_" + origin + 0x00 + <format><content>.
private func dataKey(origin: String, key: [UInt8]) -> [UInt8] {
    [0x5F] + Array(origin.utf8) + [0x00] + key
}
private func utf16Value(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = [0x00]
    for unit in string.utf16 { bytes.append(UInt8(unit & 0xff)); bytes.append(UInt8(unit >> 8)) }
    return bytes
}
private func latin1Value(_ bytes: [UInt8]) -> [UInt8] { [0x01] + bytes }

@Test func localStorageDecodesStringEncodings() {
    #expect(ChromeLocalStorageSource.decodeString(utf16Value("héllo")) == "héllo")
    #expect(ChromeLocalStorageSource.decodeString(latin1Value([0x74, 0x6f, 0x6b, 0x65, 0x6e])) == "token")
    // Odd-length UTF-16 body and an unpaired high surrogate are rejected.
    #expect(ChromeLocalStorageSource.decodeString([0x00, 0x41]) == nil)
    #expect(ChromeLocalStorageSource.decodeString([0x00, 0x00, 0xD8]) == nil)
    // Unknown format marker and empty input are rejected.
    #expect(ChromeLocalStorageSource.decodeString([0x02, 0x41]) == nil)
    #expect(ChromeLocalStorageSource.decodeString([]) == nil)
}

@Test func localStorageKeepsOnlyMatchingOrigin() {
    let origin = "https://discord.com"
    let pairs: [(key: [UInt8], value: [UInt8])] = [
        (dataKey(origin: origin, key: latin1Value(Array("token".utf8))), latin1Value(Array("secret-value".utf8))),
        (dataKey(origin: origin, key: utf16Value("locale")), utf16Value("en-US")),
        // Empty storage key (map marker) is skipped.
        (dataKey(origin: origin, key: latin1Value([])), latin1Value(Array("x".utf8))),
        // Another origin is ignored.
        (dataKey(origin: "https://evil.test", key: latin1Value(Array("token".utf8))), latin1Value(Array("nope".utf8))),
        // Metadata key (META: prefix) is ignored.
        (Array("META:https://discord.com".utf8), latin1Value(Array("x".utf8))),
    ]
    let read = ChromeLocalStorageSource.decode(pairs, origin: origin)
    let items = Dictionary(uniqueKeysWithValues: read.items.map { ($0.key, $0.value) })
    #expect(items == ["token": "secret-value", "locale": "en-US"])
    #expect(read.items.count == 2)
}

@Test func localStorageDropsUndecodableValueButKeepsCount() {
    let origin = "https://discord.com"
    let pairs: [(key: [UInt8], value: [UInt8])] = [
        (dataKey(origin: origin, key: latin1Value(Array("good".utf8))), latin1Value(Array("v".utf8))),
        (dataKey(origin: origin, key: latin1Value(Array("bad".utf8))), [0x00, 0x41]), // odd UTF-16 body
    ]
    let read = ChromeLocalStorageSource.decode(pairs, origin: origin)
    #expect(read.items.map(\.key) == ["good"])
    #expect(read.unsupported == 1)
}

@Test func jsStringLiteralEscapesControlAndLineSeparators() {
    #expect(ChromeCookieImporter.jsStringLiteral("a\"b\\c") == "\"a\\\"b\\\\c\"")
    #expect(ChromeCookieImporter.jsStringLiteral("x\ny") == "\"x\\ny\"")
    #expect(ChromeCookieImporter.jsStringLiteral("x\u{2028}y") == "\"x\\u2028y\"")
    #expect(ChromeCookieImporter.jsStringLiteral("x\u{0001}y") == "\"x\\u0001y\"")
}
