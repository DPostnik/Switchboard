import Foundation

/// Minimal, read-only LevelDB reader for the database Chrome uses for Local Storage.
/// It never opens a real DB and never writes: it parses a private snapshot copy of the
/// directory and returns the live key/value pairs. All multi-byte integers are little-endian.
public enum ChromeLevelDB {
    public enum Failure: Error, Equatable { case malformed, tooLarge }

    static let maximumEntries = 200_000
    static let maximumValueBytes = 8 * 1024 * 1024
    static let maximumTotalBytes = 64 * 1024 * 1024
    static let blockSize = 32768
    static let tableMagic: UInt64 = 0xdb4775248b80fb57

    /// Live key/value byte pairs from a snapshot directory. Newest write per user key wins
    /// (by LevelDB sequence number); deleted keys are dropped. Throws on malformed input or
    /// when size caps are exceeded, rather than returning partial data. Pure read: opens no DB,
    /// writes nothing. Order of the returned array is unspecified.
    public static func read(directory: URL) throws -> [(key: [UInt8], value: [UInt8])] {
        let fm = FileManager.default
        var tableFiles: [URL] = [], logFiles: [URL] = [], usedManifest = false

        // Current version: CURRENT names the MANIFEST; the MANIFEST (log format) lists live tables.
        if let current = try? readFile(directory.appendingPathComponent("CURRENT")),
           let name = String(bytes: current, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, !name.contains("/"), !name.contains(".."),
           let manifest = try? readFile(directory.appendingPathComponent(name)) {
            let live = try liveFiles(logRecords(manifest))
            usedManifest = true
            for number in live.tables {
                let ldb = directory.appendingPathComponent(String(format: "%06d.ldb", number))
                let sst = directory.appendingPathComponent(String(format: "%06d.sst", number))
                if fm.fileExists(atPath: ldb.path) { tableFiles.append(ldb) }
                else if fm.fileExists(atPath: sst.path) { tableFiles.append(sst) }
                // A listed file that is gone from the snapshot is skipped, not treated as corruption.
            }
            for number in [live.logNumber, live.prevLogNumber].compactMap({ $0 }) where number != 0 {
                let log = directory.appendingPathComponent(String(format: "%06d.log", number))
                if fm.fileExists(atPath: log.path) { logFiles.append(log) }
            }
        }
        // Fallback when CURRENT/MANIFEST is missing or unreadable: read every table and log file.
        // Chrome Local Storage directories are tiny, so this keeps the reader robust.
        if !usedManifest {
            for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                switch url.pathExtension.lowercased() {
                case "ldb", "sst": tableFiles.append(url)
                case "log": logFiles.append(url)
                default: break
                }
            }
        }

        var entries: [Entry] = [], accumulated = 0
        func add(_ batch: [Entry]) throws {
            for entry in batch {
                accumulated += entry.key.count + entry.value.count
                guard accumulated <= maximumTotalBytes else { throw Failure.tooLarge }
                entries.append(entry)
            }
        }
        for url in tableFiles { try add(tableEntries(readFile(url))) }
        for url in logFiles { for record in try logRecords(readFile(url)) { try add(writeBatch(record)) } }

        // Keep the highest-sequence record per user key; drop keys whose winner is a deletion.
        var winners: [[UInt8]: Entry] = [:]
        for entry in entries {
            if let current = winners[entry.key], current.sequence > entry.sequence { continue }
            winners[entry.key] = entry
        }
        var result: [(key: [UInt8], value: [UInt8])] = [], total = 0
        for entry in winners.values where !entry.deleted {
            total += entry.key.count + entry.value.count
            guard total <= maximumTotalBytes else { throw Failure.tooLarge }
            result.append((key: entry.key, value: entry.value))
            guard result.count <= maximumEntries else { throw Failure.tooLarge }
        }
        return result
    }

    struct Entry { let key: [UInt8]; let sequence: UInt64; let deleted: Bool; let value: [UInt8] }

    static func readFile(_ url: URL) throws -> [UInt8] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.malformed }
        guard size <= maximumTotalBytes else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw Failure.malformed }
        return [UInt8](data)
    }

    // MARK: Bytes

    private struct Cursor {
        let bytes: [UInt8]
        var offset: Int
        init(_ bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }
        var remaining: Int { bytes.count - offset }
        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw Failure.malformed }
            defer { offset += 1 }; return bytes[offset]
        }
        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, n <= bytes.count - offset else { throw Failure.malformed }
            defer { offset += n }; return bytes[offset..<offset + n]
        }
        mutating func uint32() throws -> UInt32 { var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(try byte()) << (8 * i) }; return v }
        mutating func uint64() throws -> UInt64 { var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(try byte()) << (8 * i) }; return v }
        mutating func varint64() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard shift < 64 else { throw Failure.malformed }
                let b = try byte()
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }
        mutating func varint32() throws -> UInt32 {
            let v = try varint64()
            guard v <= UInt64(UInt32.max) else { throw Failure.malformed }
            return UInt32(v)
        }
    }

    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        out.append(UInt8(v)); return out
    }
    static func decodeVarint(_ bytes: [UInt8]) throws -> UInt64 { var c = Cursor(bytes); return try c.varint64() }

    // MARK: CRC32C (Castagnoli, reflected)

    static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x82F63B78 : crc >> 1 }
            table[i] = crc
        }
        return table
    }()
    static func crc32c<C: Sequence>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(b)) & 0xFF)] }
        return crc ^ 0xFFFFFFFF
    }
    static func maskCRC(_ crc: UInt32) -> UInt32 { ((crc >> 15) | (crc << 17)) &+ 0xA282EAD8 }
    static func unmaskCRC(_ masked: UInt32) -> UInt32 { let rot = masked &- 0xA282EAD8; return (rot >> 17) | (rot << 15) }

    // MARK: Snappy (block format)

    static func snappyDecompress(_ bytes: [UInt8]) throws -> [UInt8] {
        var c = Cursor(bytes)
        let declared = try c.varint64()
        guard declared <= UInt64(maximumTotalBytes) else { throw Failure.tooLarge }
        var output: [UInt8] = []; output.reserveCapacity(Int(declared))
        while c.remaining > 0 {
            let tag = try c.byte()
            if tag & 0x03 == 0 {
                var length = Int(tag >> 2)
                if length >= 60 {
                    var value = 0
                    for i in 0..<(length - 59) { value |= Int(try c.byte()) << (8 * i) }
                    length = value
                }
                output.append(contentsOf: try c.take(length + 1))
            } else {
                let length: Int, offset: Int
                switch tag & 0x03 {
                case 1:
                    length = Int((tag >> 2) & 0x7) + 4
                    offset = (Int(tag >> 5) << 8) | Int(try c.byte())
                case 2:
                    length = Int(tag >> 2) + 1
                    let b0 = try c.byte(); let b1 = try c.byte()
                    offset = Int(b0) | (Int(b1) << 8)
                default:
                    length = Int(tag >> 2) + 1
                    let b0 = try c.byte(); let b1 = try c.byte(); let b2 = try c.byte(); let b3 = try c.byte()
                    offset = Int(b0) | (Int(b1) << 8) | (Int(b2) << 16) | (Int(b3) << 24)
                }
                guard offset >= 1, offset <= output.count else { throw Failure.malformed }
                for _ in 0..<length { output.append(output[output.count - offset]) }
            }
            guard output.count <= maximumTotalBytes else { throw Failure.tooLarge }
        }
        guard output.count == Int(declared) else { throw Failure.malformed }
        return output
    }

    // MARK: Log / MANIFEST records (same 32KiB-block physical format)

    static func logRecords(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var records: [[UInt8]] = [], pending: [UInt8]? = nil, offset = 0
        while offset < bytes.count {
            let blockEnd = min(offset + blockSize, bytes.count)
            while blockEnd - offset >= 7 {
                let crc = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                let type = bytes[offset + 6]
                if crc == 0, length == 0, type == 0 { break } // zero padding to the block boundary
                let start = offset + 7
                guard start + length <= blockEnd else { throw Failure.malformed }
                let payload = Array(bytes[start..<start + length])
                guard unmaskCRC(crc) == crc32c([type] + payload) else { throw Failure.malformed }
                offset = start + length
                switch type {
                case 1: guard pending == nil else { throw Failure.malformed }; records.append(payload)
                case 2: guard pending == nil else { throw Failure.malformed }; pending = payload
                case 3: guard pending != nil else { throw Failure.malformed }; pending!.append(contentsOf: payload)
                case 4:
                    guard pending != nil else { throw Failure.malformed }
                    pending!.append(contentsOf: payload); records.append(pending!); pending = nil
                default: throw Failure.malformed
                }
            }
            offset = blockEnd
        }
        guard pending == nil else { throw Failure.malformed }
        return records
    }

    /// A reassembled log record is a WriteBatch: 8-byte sequence, 4-byte count, then entries.
    /// The log stores plain user keys; the i-th entry's sequence is batchSequence + i.
    static func writeBatch(_ record: [UInt8]) throws -> [Entry] {
        var c = Cursor(record)
        let sequence = try c.uint64(), count = try c.uint32()
        var entries: [Entry] = []
        for i in 0..<Int(count) {
            let tag = try c.byte()
            let key = Array(try c.take(Int(try c.varint32())))
            let seq = sequence &+ UInt64(i)
            switch tag {
            case 1:
                let length = Int(try c.varint32())
                guard length <= maximumValueBytes else { throw Failure.tooLarge }
                entries.append(Entry(key: key, sequence: seq, deleted: false, value: Array(try c.take(length))))
            case 0:
                entries.append(Entry(key: key, sequence: seq, deleted: true, value: []))
            default: throw Failure.malformed
            }
        }
        return entries
    }

    // MARK: Sorted tables (.ldb / .sst)

    static func tableEntries(_ bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= 48 else { throw Failure.malformed }
        var footer = Cursor(bytes, offset: bytes.count - 8)
        guard try footer.uint64() == tableMagic else { throw Failure.malformed }
        footer = Cursor(bytes, offset: bytes.count - 48)
        _ = try blockHandle(&footer)                 // metaindex handle, unused for value extraction
        let index = try blockHandle(&footer)
        var entries: [Entry] = []
        for indexEntry in try blockKeyValues(blockContents(bytes, handle: index)) {
            var handle = Cursor(indexEntry.value)
            for data in try blockKeyValues(blockContents(bytes, handle: try blockHandle(&handle))) {
                // In a data block each key is an internal key: user_key + 8-byte trailer.
                guard data.key.count >= 8 else { throw Failure.malformed }
                let userKey = Array(data.key[0..<data.key.count - 8])
                var trailer: UInt64 = 0
                for i in 0..<8 { trailer |= UInt64(data.key[data.key.count - 8 + i]) << (8 * i) }
                let deleted: Bool
                switch trailer & 0xff { case 1: deleted = false; case 0: deleted = true; default: throw Failure.malformed }
                guard data.value.count <= maximumValueBytes else { throw Failure.tooLarge }
                entries.append(Entry(key: userKey, sequence: trailer >> 8, deleted: deleted, value: data.value))
            }
        }
        return entries
    }

    private static func blockHandle(_ c: inout Cursor) throws -> (offset: Int, size: Int) {
        let offset = try c.varint64(), size = try c.varint64()
        guard offset <= UInt64(Int.max), size <= UInt64(Int.max) else { throw Failure.malformed }
        return (Int(offset), Int(size))
    }

    /// Reads a block's bytes, validating the 1-byte compression type and bounds (crc check skipped).
    private static func blockContents(_ bytes: [UInt8], handle: (offset: Int, size: Int)) throws -> [UInt8] {
        let (offset, size) = handle
        guard offset >= 0, size >= 0, offset <= bytes.count, size <= bytes.count - offset, size + 5 <= bytes.count - offset else { throw Failure.malformed }
        let raw = Array(bytes[offset..<offset + size])
        switch bytes[offset + size] {
        case 0: return raw
        case 1: return try snappyDecompress(raw)
        default: throw Failure.malformed
        }
    }

    struct KeyValue { let key: [UInt8]; let value: [UInt8] }

    /// Parses a decompressed block: prefix-compressed entries followed by a uint32 restart array.
    private static func blockKeyValues(_ block: [UInt8]) throws -> [KeyValue] {
        guard block.count >= 4 else { throw Failure.malformed }
        var tail = Cursor(block, offset: block.count - 4)
        let restarts = Int(try tail.uint32())
        guard restarts >= 0, restarts <= (block.count - 4) / 4 else { throw Failure.malformed }
        let end = block.count - 4 - restarts * 4
        var c = Cursor(block), lastKey: [UInt8] = [], result: [KeyValue] = []
        while c.offset < end {
            let shared = Int(try c.varint32()), nonShared = Int(try c.varint32()), valueLen = Int(try c.varint32())
            guard shared <= lastKey.count, c.offset + nonShared <= end else { throw Failure.malformed }
            var key = Array(lastKey[0..<shared]); key.append(contentsOf: try c.take(nonShared))
            guard c.offset + valueLen <= end else { throw Failure.malformed }
            result.append(KeyValue(key: key, value: Array(try c.take(valueLen))))
            lastKey = key
        }
        guard c.offset == end else { throw Failure.malformed }
        return result
    }

    // MARK: MANIFEST VersionEdit parsing (live-file selection)

    /// Accumulates live table file numbers across all VersionEdit records (tag 7 adds, tag 6 removes),
    /// and notes the current and previous log file numbers (tags 2 and 9).
    static func liveFiles(_ records: [[UInt8]]) throws -> (tables: Set<UInt64>, logNumber: UInt64?, prevLogNumber: UInt64?) {
        var tables: Set<UInt64> = [], logNumber: UInt64? = nil, prevLogNumber: UInt64? = nil
        for record in records {
            var c = Cursor(record)
            while c.remaining > 0 {
                switch try c.varint32() {
                case 1: _ = try c.take(Int(try c.varint32()))                 // comparator name
                case 2: logNumber = try c.varint64()                           // log_number
                case 3: _ = try c.varint64()                                   // next_file_number
                case 4: _ = try c.varint64()                                   // last_sequence
                case 5: _ = try c.varint32(); _ = try c.take(Int(try c.varint32())) // compact_pointer
                case 6: _ = try c.varint32(); tables.remove(try c.varint64())  // deleted_file
                case 7:                                                        // new_file
                    _ = try c.varint32(); let number = try c.varint64(); _ = try c.varint64()
                    _ = try c.take(Int(try c.varint32())); _ = try c.take(Int(try c.varint32()))
                    tables.insert(number)
                case 9: prevLogNumber = try c.varint64()                       // prev_log_number
                default: throw Failure.malformed
                }
            }
        }
        return (tables, logNumber, prevLogNumber)
    }
}
