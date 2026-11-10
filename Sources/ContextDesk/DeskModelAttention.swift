import Foundation

extension DeskModel {
    /// Waiting chats already represent their notifications. Keep the underlying notices for acknowledgement.
    var attentionNotices: [DeskNotice] {
        let waiting = Set(attentionChats.map { $0.chat.id })
        return notices.filter { !waiting.contains($0.threadID) }
    }

    /// Use the same entries for the badge and the Needs you page.
    var needsYouCount: Int {
        attentionChats.count + openAttentionCount + attentionNotices.count + pullRequests.openAlerts.count
    }
}
