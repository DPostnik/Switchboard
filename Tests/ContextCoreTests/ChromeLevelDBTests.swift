import Foundation
import Testing
@testable import ContextCore

// Hand-built LevelDB fixtures only; no Chrome profile or real database is read.

private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xff) } }
private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Internal key = user key + 8-byte trailer (sequence << 8 | type), type 1 = value, 0 = deletion.
private func internalKey(_ user: [UInt8], sequence: UInt64, type: UInt8) -> [UInt8] {
    user + le64((sequence << 8) | UInt64(type))
}

/// WriteBatch: 8-byte sequence, 4-byte count, then tagged entries (tag 1 put, tag 0 delete).
private func writeBatch(sequence: UInt64, _ ops: [(key: [UInt8], value: [UInt8]?)]) -> [UInt8] {
    var out = le64(sequence) + le32(UInt32(ops.count))
    for op in ops {
        if let value = op.value {
            out += [1] + ChromeLevelDB.encodeVarint(UInt64(op.key.count)) + op.key
                + ChromeLevelDB.encodeVarint(UInt64(value.count)) + value
        } else {
            out += [0] + ChromeLevelDB.encodeVarint(UInt64(op.key.count)) + op.key
        }
    }
    return out
}

/// Encodes records into the 32768-byte-block log format, fragmenting across blocks with correct crcs.
private func encodeLog(_ records: [[UInt8]]) -> [UInt8] {
    let block = 32768, header = 7
    var out: [UInt8] = []
    for record in records {
        var payload = record[...]
        var first = true
        while true {
            if block - (out.count % block) < header { out.append(contentsOf: repeatElement(0, count: block - (out.count % block))) }
            let room = block - (out.count % block) - header
            let fragLen = min(room, payload.count)
            let last = fragLen == payload.count
            let type: UInt8 = first && last ? 1 : first ? 2 : last ? 4 : 3
            let frag = Array(payload.prefix(fragLen))
            let crc = ChromeLevelDB.maskCRC(ChromeLevelDB.crc32c([type] + frag))
            out += le32(crc) + [UInt8(fragLen & 0xff), UInt8((fragLen >> 8) & 0xff), type] + frag
            payload = payload.dropFirst(fragLen)
            first = false
            if last { break }
        }
    }
    return out
}

/// Block body: prefix-compressed entries (all with shared = 0) plus a single-restart array.
private func encodeBlock(_ entries: [(key: [UInt8], value: [UInt8])]) -> [UInt8] {
    var out: [UInt8] = []
    for e in entries {
        out += ChromeLevelDB.encodeVarint(0) + ChromeLevelDB.encodeVarint(UInt64(e.key.count))
            + ChromeLevelDB.encodeVarint(UInt64(e.value.count)) + e.key + e.value
    }
    return out + le32(0) + le32(1)
}

/// Builds a one-data-block sorted table: data block, empty metaindex, one-entry index, footer with magic.
private func encodeTable(_ entries: [(key: [UInt8], value: [UInt8])]) -> [UInt8] {
    func withTrailer(_ b: [UInt8]) -> [UInt8] { b + [0] + le32(0) } // compression 0, crc ignored by reader
    var file: [UInt8] = []
    let dataOffset = file.count, dataBlock = encodeBlock(entries)
    file += withTrailer(dataBlock)
    let metaOffset = file.count, metaBlock = encodeBlock([])
    file += withTrailer(metaBlock)
    let dataHandle = ChromeLevelDB.encodeVarint(UInt64(dataOffset)) + ChromeLevelDB.encodeVarint(UInt64(dataBlock.count))
    let indexOffset = file.count, indexBlock = encodeBlock([(key: bytes("z"), value: dataHandle)])
    file += withTrailer(indexBlock)
    var footer = ChromeLevelDB.encodeVarint(UInt64(metaOffset)) + ChromeLevelDB.encodeVarint(UInt64(metaBlock.count))
        + ChromeLevelDB.encodeVarint(UInt64(indexOffset)) + ChromeLevelDB.encodeVarint(UInt64(indexBlock.count))
    while footer.count < 40 { footer.append(0) }
    footer += le64(0xdb4775248b80fb57)
    return file + footer
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func sorted(_ pairs: [(key: [UInt8], value: [UInt8])]) -> [(key: [UInt8], value: [UInt8])] {
    pairs.sorted { lexLess($0.key, $1.key) }
}
private func lexLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    for (x, y) in zip(a, b) where x != y { return x < y }
    return a.count < b.count
}

@Test func levelDBCRC32CMatchesKnownVectorAndMaskRoundTrips() {
    #expect(ChromeLevelDB.crc32c(bytes("123456789")) == 0xE3069283)
    for value: UInt32 in [0, 1, 0xE3069283, 0xFFFFFFFF, 0x12345678] {
        #expect(ChromeLevelDB.unmaskCRC(ChromeLevelDB.maskCRC(value)) == value)
    }
}

@Test func levelDBVarintRoundTrips() throws {
    for value: UInt64 in [0, 127, 128, 300, 1 << 32, .max] {
        #expect(try ChromeLevelDB.decodeVarint(ChromeLevelDB.encodeVarint(value)) == value)
    }
    #expect(ChromeLevelDB.encodeVarint(0) == [0])
    #expect(ChromeLevelDB.encodeVarint(300) == [0xAC, 0x02])
    #expect(throws: ChromeLevelDB.Failure.malformed) { try ChromeLevelDB.decodeVarint([0x80, 0x80]) } // never terminates
}

@Test func levelDBSnappyDecompressesCanonicalVectors() throws {
    #expect(try ChromeLevelDB.snappyDecompress([0x00]) == [])                       // empty
    // Pure literal "hello": declared length 5, literal tag (len-1 = 4) then raw bytes.
    #expect(try ChromeLevelDB.snappyDecompress([0x05, 0x10] + bytes("hello")) == bytes("hello"))
    // Overlapping copy: literal 'a', then 1-byte-offset copy length 4 offset 1 => "aaaaa".
    #expect(try ChromeLevelDB.snappyDecompress([0x05, 0x00, 0x61, 0x01, 0x01]) == bytes("aaaaa"))
    #expect(throws: ChromeLevelDB.Failure.malformed) { try ChromeLevelDB.snappyDecompress([0x05, 0x00, 0x61]) } // short
    #expect(throws: ChromeLevelDB.Failure.malformed) { try ChromeLevelDB.snappyDecompress([0x05, 0x01, 0x01]) } // offset past output
}

@Test func levelDBReadsLogPutsAppliesDeletionsAndNewestWins() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let batchA = writeBatch(sequence: 1, [(bytes("k1"), bytes("old")), (bytes("k2"), bytes("v2")), (bytes("k3"), bytes("v3"))])
    let batchB = writeBatch(sequence: 4, [(bytes("k1"), bytes("new")), (bytes("k2"), nil)])
    try Data(encodeLog([batchA, batchB])).write(to: root.appendingPathComponent("000003.log"))

    let result = sorted(try ChromeLevelDB.read(directory: root))
    #expect(result.count == 2)
    #expect(result.map { $0.key } == [bytes("k1"), bytes("k3")])
    #expect(result.map { $0.value } == [bytes("new"), bytes("v3")])
}

@Test func levelDBReadsSortedTableAndLogOverridesByHigherSequence() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let table = encodeTable([
        (internalKey(bytes("a"), sequence: 5, type: 1), bytes("av")),
        (internalKey(bytes("b"), sequence: 6, type: 1), bytes("bv"))])
    try Data(table).write(to: root.appendingPathComponent("000007.ldb"))

    var result = sorted(try ChromeLevelDB.read(directory: root))
    #expect(result.map { $0.key } == [bytes("a"), bytes("b")])
    #expect(result.map { $0.value } == [bytes("av"), bytes("bv")])

    // A log put with a higher sequence overrides the table value for "a".
    try Data(encodeLog([writeBatch(sequence: 100, [(bytes("a"), bytes("anew"))])])).write(to: root.appendingPathComponent("000008.log"))
    result = sorted(try ChromeLevelDB.read(directory: root))
    #expect(result.map { $0.key } == [bytes("a"), bytes("b")])
    #expect(result.map { $0.value } == [bytes("anew"), bytes("bv")])
}

@Test func levelDBRejectsValuesOverTheSizeCap() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let big = [UInt8](repeating: 0x7a, count: 8 * 1024 * 1024 + 1)
    try Data(encodeLog([writeBatch(sequence: 1, [(bytes("big"), big)])])).write(to: root.appendingPathComponent("000003.log"))
    #expect(throws: ChromeLevelDB.Failure.tooLarge) { try ChromeLevelDB.read(directory: root) }
}
