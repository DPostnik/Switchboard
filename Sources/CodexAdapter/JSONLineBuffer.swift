import Foundation
import ContextCore

/// Scan each incoming byte once, even when a large history reply arrives in tiny chunks.
struct JSONLineBuffer {
    /// A line over the limit is skipped, not buffered: only its head remains, to route a notice about it.
    enum Line: Equatable {
        case complete(Data)
        case oversized(head: Data, bytes: Int)
    }
    static let headBytes = 64 * 1024
    private var partial = Data()
    /// Size of the oversized line being skipped; nil while the current line is within the limit.
    private var skipped: Int?
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 32 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ chunk: Data) -> [Line] {
        var lines: [Line] = []
        chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            for index in bytes.indices where bytes[index] == 10 {
                appendSegment(bytes[start..<index])
                lines.append(skipped.map { .oversized(head: partial, bytes: $0) } ?? .complete(partial))
                partial = Data(); skipped = nil
                start = index + 1
            }
            appendSegment(bytes[start..<bytes.count])
        }
        return lines
    }

    private mutating func appendSegment(_ bytes: Slice<UnsafeRawBufferPointer>) {
        if let count = skipped { skipped = count + bytes.count; return }
        guard bytes.count > maximumLineBytes - partial.count else { partial.append(contentsOf: bytes); return }
        skipped = partial.count + bytes.count
        if partial.count > Self.headBytes { partial = Data(partial.prefix(Self.headBytes)) }
        partial.append(contentsOf: bytes.prefix(Self.headBytes - partial.count))
    }
}

/// Envelope fields read from the head of a skipped JSON-RPC line. The body is data and is never decoded.
struct OversizedLineHead: Equatable {
    var id: JSONValue?
    var method: String?
    var threadID: String?

    private static let envelope = try! NSRegularExpression(pattern:
        #"^\s*\{\s*(?:"jsonrpc"\s*:\s*"[^"\\]*"\s*,\s*)?(?:"id"\s*:\s*(-?\d+|"[^"\\]*")\s*,\s*)?(?:"method"\s*:\s*"([^"\\]+)"|"(?:result|error)"\s*:)"#)
    private static let thread = try! NSRegularExpression(pattern: #""threadId"\s*:\s*"([^"\\]+)""#)

    init(id: JSONValue? = nil, method: String? = nil, threadID: String? = nil) {
        self.id = id; self.method = method; self.threadID = threadID
    }

    init(_ head: Data) {
        let text = String(decoding: head, as: UTF8.self), range = NSRange(text.startIndex..., in: text)
        func group(_ match: NSTextCheckingResult?, _ index: Int) -> String? {
            guard let match, let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        let envelope = Self.envelope.firstMatch(in: text, range: range)
        id = group(envelope, 1).flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        method = group(envelope, 2)
        threadID = group(Self.thread.firstMatch(in: text, range: range), 1)
    }
}
