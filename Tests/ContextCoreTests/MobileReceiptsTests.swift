import Foundation
import Testing
import ContextCore

/// In-memory Keychain stand-in keyed by account.
private final class ReceiptVault: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var storage: RemoteSessionStorage {
        RemoteSessionStorage(read: { account in self.lock.withLock { self.items[account] } },
                             write: { data, account in self.lock.withLock { self.items[account] = data } })
    }
    subscript(account: String) -> Data? {
        get { lock.withLock { items[account] } }
        set { lock.withLock { items[account] = newValue } }
    }
}

private let mac = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
private let project = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

private func send(_ chat: String, device: String = mac) -> RemoteCommand {
    RemoteCommand(owner: "owner", device: device, project: project, chat: chat, kind: "send", text: "Hello")
}

@Test func uncertainReceiptBlocksOnlyItsOwnChat() {
    var receipts = RemoteReceipts()
    let first = send("chat-a")
    receipts.record(first)
    #expect(receipts.blocks(device: mac, chat: "chat-a"))
    #expect(receipts.blocks(device: mac.lowercased(), chat: "chat-a"), "Device IDs compare case-insensitively")
    #expect(!receipts.blocks(device: mac, chat: "chat-b"))
    #expect(!receipts.blocks(device: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", chat: "chat-a"), "The same chat ID on another Mac is a different chat")
    receipts.record(send("chat-b"))
    receipts.record(first)
    #expect(receipts.commands.count == 2, "Recording the same command twice keeps one receipt")
    #expect(receipts.resolve(known: [first.id.uppercased()]) == [first.id])
    #expect(!receipts.blocks(device: mac, chat: "chat-a"))
    #expect(receipts.blocks(device: mac, chat: "chat-b"))
}

@Test func receiptsNeverStorePhotosAndRoundTrip() throws {
    let vault = ReceiptVault()
    var command = send("chat-a")
    command.photos = [RemotePhoto(data: Data([0xff, 0xd8, 0xff, 0x00]))]
    var receipts = RemoteReceipts()
    receipts.record(command)
    try receipts.save(to: vault.storage)
    let loaded = try RemoteReceipts.load(from: vault.storage)
    #expect(loaded.commands.map(\.id) == [command.id])
    #expect(loaded.commands[0].photos == nil)
    #expect(String(decoding: try #require(vault[RemoteReceipts.account]), as: UTF8.self).contains("photos") == false)

    receipts.remove(command.id)
    try receipts.save(to: vault.storage)
    #expect(vault[RemoteReceipts.account] == nil, "An empty list removes the Keychain item")
}

@Test func legacySingleReceiptMigratesIntoItsChat() throws {
    let vault = ReceiptVault()
    let legacy = send("chat-a")
    vault[RemoteReceipts.legacyAccount] = try JSONEncoder().encode(legacy)
    let receipts = try RemoteReceipts.load(from: vault.storage)
    #expect(receipts.commands.map(\.id) == [legacy.id])
    #expect(receipts.blocks(device: mac, chat: "chat-a"))
    #expect(!receipts.blocks(device: mac, chat: "chat-b"))
    #expect(vault[RemoteReceipts.legacyAccount] == nil)
    #expect(vault[RemoteReceipts.account] != nil)

    // An interrupted migration (list written, legacy item still present) does not duplicate it.
    vault[RemoteReceipts.legacyAccount] = try JSONEncoder().encode(legacy)
    let again = try RemoteReceipts.load(from: vault.storage)
    #expect(again.commands.map(\.id) == [legacy.id])
    #expect(vault[RemoteReceipts.legacyAccount] == nil)
}

@Test func unresolvedCreationBlocksAnotherCreationInTheSameProjectOnly() {
    var receipts = RemoteReceipts()
    let created = RemoteCommand.newChat(owner: "owner", device: mac, project: project, text: "Start")
    receipts.record(created)
    #expect(receipts.creations(device: mac, project: project).map(\.id) == [created.id])
    #expect(receipts.creations(device: mac, project: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC").isEmpty)
    #expect(receipts.blocks(device: mac, chat: created.chat))
    #expect(!receipts.blocks(device: mac, chat: "chat-a"))
}

@Test func unreadableReceiptFailsClosed() {
    let vault = ReceiptVault()
    vault[RemoteReceipts.legacyAccount] = Data("not json".utf8)
    #expect(throws: (any Error).self) { try RemoteReceipts.load(from: vault.storage) }
    #expect(vault[RemoteReceipts.legacyAccount] != nil, "A receipt that cannot be read is never dropped")
}
