import Foundation

/// Phone-side delivery receipts: commands whose queue insert is not confirmed yet.
///
/// A receipt is saved before networking and removed once the cloud queue is known to hold
/// the command (or to have rejected it). It is never resent automatically. A receipt blocks
/// later commands only in its own chat (device + chat); other chats stay usable.
public struct RemoteReceipts: Sendable {
    /// Keychain account of the receipt list.
    public static let account = "pending-commands"
    /// Single receipt written by phone builds before per-chat receipts; migrated on load.
    public static let legacyAccount = "pending-command"

    /// Oldest first. Photos are never stored: the receipt holds identity and text only.
    public private(set) var commands: [RemoteCommand]

    public init(_ commands: [RemoteCommand] = []) {
        self.commands = []
        commands.forEach { record($0) }
    }

    /// Reads the list and folds in a legacy single receipt. The list is written before the
    /// legacy item is removed, so an interruption can repeat the migration but never lose it.
    public static func load(from storage: RemoteSessionStorage) throws -> Self {
        var value = Self(try storage.read(account).map { try JSONDecoder().decode([RemoteCommand].self, from: $0) } ?? [])
        if let data = try storage.read(legacyAccount) {
            if !data.isEmpty { value.record(try JSONDecoder().decode(RemoteCommand.self, from: data)) }
            try value.save(to: storage)
            try storage.write(nil, legacyAccount)
        }
        return value
    }

    public func save(to storage: RemoteSessionStorage) throws {
        try storage.write(commands.isEmpty ? nil : JSONEncoder().encode(commands), Self.account)
    }

    public var isEmpty: Bool { commands.isEmpty }

    /// The unresolved command of one chat, if any. Device IDs compare case-insensitively.
    public func receipt(device: String, chat: String) -> RemoteCommand? {
        commands.first { $0.device.lowercased() == device.lowercased() && $0.chat == chat }
    }

    /// Whether a new command in this chat must wait for the user to resolve an earlier one.
    public func blocks(device: String, chat: String) -> Bool { receipt(device: device, chat: chat) != nil }

    /// Unresolved chat creations in one project. A second creation there could duplicate the first.
    public func creations(device: String, project: String) -> [RemoteCommand] {
        commands.filter { $0.createsChat && $0.device.lowercased() == device.lowercased() && $0.project.lowercased() == project.lowercased() }
    }

    public func contains(_ id: String) -> Bool { commands.contains { $0.id.lowercased() == id.lowercased() } }

    /// Adds a receipt without its photos. A command already recorded is kept once.
    public mutating func record(_ command: RemoteCommand) {
        guard !contains(command.id) else { return }
        var receipt = command; receipt.photos = nil
        commands.append(receipt)
    }

    @discardableResult public mutating func remove(_ id: String) -> Bool {
        let count = commands.count
        commands.removeAll { $0.id.lowercased() == id.lowercased() }
        return commands.count != count
    }

    /// Drops receipts whose commands the cloud queue reported. Returns the removed IDs.
    @discardableResult public mutating func resolve(known ids: some Sequence<String>) -> [String] {
        let known = Set(ids.map { $0.lowercased() })
        let removed = commands.filter { known.contains($0.id.lowercased()) }.map(\.id)
        commands.removeAll { known.contains($0.id.lowercased()) }
        return removed
    }
}
