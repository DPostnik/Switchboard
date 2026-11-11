@testable import CodexAdapter
import Foundation
import Testing
@testable import ContextCore

@Test func fragmentedLargeHistoryIsScannedInLinearTime() throws {
    var buffer = JSONLineBuffer()
    let chunk = Data(repeating: 120, count: 1024)
    let started = ContinuousClock.now
    for _ in 0..<8192 { #expect(buffer.append(chunk).isEmpty) }
    let lines = buffer.append(Data("\nnext\npartial".utf8))
    #expect(lines == [.complete(Data(repeating: 120, count: 8 * 1024 * 1024)), .complete(Data("next".utf8))])
    #expect(buffer.append(Data(" reply\n".utf8)) == [.complete(Data("partial reply".utf8))])
    // Generous bound: the former full-buffer rescans take minutes for this input.
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test func lineBufferHandlesSlicesEmptyLinesAndSplitUnicode() throws {
    var buffer = JSONLineBuffer()
    let bytes = Data("xxПривет ✅\n\nlast\n".utf8).dropFirst(2)
    var lines: [JSONLineBuffer.Line] = []
    for index in bytes.indices { lines += buffer.append(bytes[index...index]) }
    #expect(lines == [.complete(Data("Привет ✅".utf8)), .complete(Data()), .complete(Data("last".utf8))])
    #expect(buffer.append(Data()).isEmpty)
}

@Test func oversizedLinesAreSkippedAcrossChunksKeepingOnlyTheirHead() throws {
    var buffer = JSONLineBuffer(maximumLineBytes: 4)
    #expect(buffer.append(Data("1234\n1234\n12".utf8)).count == 2)
    #expect(buffer.append(Data("345".utf8)).isEmpty)
    #expect(buffer.append(Data("67\nok\n".utf8)) == [.oversized(head: Data("12345".utf8), bytes: 7), .complete(Data("ok".utf8))])
    var single = JSONLineBuffer(maximumLineBytes: 4)
    #expect(single.append(Data("12345\nnext\n".utf8)) == [.oversized(head: Data("12345".utf8), bytes: 5), .complete(Data("next".utf8))])
    var long = JSONLineBuffer(maximumLineBytes: 4)
    let body = Data(repeating: 120, count: JSONLineBuffer.headBytes + 10)
    #expect(long.append(body + Data(repeating: 120, count: 10) + Data("\n".utf8))
        == [.oversized(head: Data(repeating: 120, count: JSONLineBuffer.headBytes), bytes: JSONLineBuffer.headBytes + 20)])
}

@Test func oversizedLineHeadReadsOnlyTheEnvelope() throws {
    func head(_ text: String) -> OversizedLineHead { OversizedLineHead(Data(text.utf8)) }
    #expect(head(#"{"id":"7","result":{"data":"xx"#) == .init(id: .string("7")))
    #expect(head(#"{"id":12,"method":"item/tool/call","params":{"threadId":"t1","x":"#)
        == .init(id: .number(12), method: "item/tool/call", threadID: "t1"))
    #expect(head(#"{"method":"item/completed","params":{"item":{"text":"\"threadId\":\"fake\""#) == .init(method: "item/completed"))
    // A nested "id" is not a reply envelope.
    #expect(head(#"{"params":{"id":"7"},"method":"x"}"#) == .init())
    #expect(head("xxxx") == .init())
}
