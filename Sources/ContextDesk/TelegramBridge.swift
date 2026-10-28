import Foundation
import SwiftUI
import ContextCore

/// Telegram alerts through the user's notifier: a chat that waits for an approval, an answer or after a failed
/// turn is sent once it waited `delay`; the question is withdrawn when the wait ends. Reply answers come back
/// into their chat. Off by default. Every notifier call runs once; a failed send is recorded and not repeated.
@MainActor final class TelegramBridge: ObservableObject {
    private enum Keys {
        static let enabled = "telegramAlertsEnabled", delay = "telegramAlertDelayMinutes", script = "telegramNotifierScript", sent = "telegramSentKeys"
    }
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled); if enabled { Task { await check() } } } }
    @Published var delayMinutes: Int { didSet { defaults.set(delayMinutes, forKey: Keys.delay) } }
    @Published var script: String { didSet { defaults.set(script, forKey: Keys.script) } }
    /// Last problem, or nil while everything works.
    @Published private(set) var problem: String?
    @Published private(set) var configured: Bool?
    private let defaults: UserDefaults
    private var firstSeen: [String: Date] = [:]
    private var sent: Set<String> { didSet { defaults.set(Array(sent).sorted(), forKey: Keys.sent) } }
    private var ticking = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Keys.enabled)
        delayMinutes = defaults.object(forKey: Keys.delay) as? Int ?? 3
        script = defaults.string(forKey: Keys.script) ?? TelegramNotifier.defaultScript
        sent = Set(defaults.stringArray(forKey: Keys.sent) ?? [])
    }

    var notifier: TelegramNotifier { TelegramNotifier(script: script) }

    func check() async {
        configured = await notifier.isConfigured()
        if configured == false { problem = L10n.text("Уведомитель не настроен или не найден.", "The notifier is not set up or not found.") }
        else { problem = nil }
    }

    func tick(model: DeskModel, now: Date = Date()) async {
        guard enabled, !ticking else { return }
        ticking = true; defer { ticking = false }
        let notifier = self.notifier
        let waiting = model.telegramWaits()
        let current = Set(waiting.map(\.key))
        for wait in waiting where firstSeen[wait.key] == nil { firstSeen[wait.key] = now }
        firstSeen = firstSeen.filter { current.contains($0.key) }
        let plan = TelegramAlerts.plan(waiting: waiting, firstSeen: firstSeen, sent: sent, now: now, delay: TimeInterval(delayMinutes * 60))
        var failure: String?
        for wait in plan.send {
            // Recorded as sent even on failure: an uncertain enqueue is never repeated.
            sent.insert(wait.key)
            do { try await notifier.enqueue(key: wait.key, job: wait.job, thread: wait.chatID, question: wait.question) }
            catch { failure = error.localizedDescription }
        }
        for key in plan.resolve {
            sent.remove(key)
            do { try await notifier.resolve(key: key) } catch { failure = error.localizedDescription }
        }
        for _ in 0..<5 {
            let reply: TelegramNotifier.Reply?
            do { reply = try await notifier.claimReply() } catch { failure = error.localizedDescription; break }
            guard let reply else { break }
            let placed = await model.acceptTelegramReply(reply)
            do { try await notifier.acknowledge(reply.id, forwarded: placed) } catch { failure = error.localizedDescription; break }
            AppLog.delivery.info("Telegram reply \(reply.id, privacy: .public) \(placed ? "placed" : "not placed", privacy: .public)")
        }
        problem = failure
    }
}

struct TelegramSettings: View {
    @ObservedObject var bridge: TelegramBridge
    var body: some View {
        Section("Telegram") {
            Toggle(L10n.text("Сообщать в Telegram, когда чат ждёт меня", "Tell me on Telegram when a chat waits for me"), isOn: $bridge.enabled)
            if bridge.enabled {
                Stepper(value: $bridge.delayMinutes, in: 0...60) {
                    Text(L10n.text("Задержка: \(bridge.delayMinutes) мин", "Delay: \(bridge.delayMinutes) min"))
                }
                TextField(L10n.text("Скрипт уведомителя", "Notifier script"), text: $bridge.script)
                    .font(.system(.body, design: .monospaced))
                if let problem = bridge.problem {
                    Text(problem).font(.ui(.caption)).foregroundStyle(.orange)
                } else if bridge.configured == true {
                    Text(L10n.text("Уведомитель настроен.", "The notifier is set up.")).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }
            Text(L10n.text("Через твой бот telegram-agent-notifier. Сообщение уходит, если чат ждёт одобрения или ответа либо ход завершился ошибкой и это длится дольше задержки; когда ожидание заканчивается, неотправленное сообщение отменяется. В сообщении название чата и суть запроса, без переписки. Ответ через Reply приходит в этот чат: подходящий вопрос получает ответ, иначе текст встаёт в очередь чата. Одобрять действия из Telegram нельзя.",
                         "Through your telegram-agent-notifier bot. A message goes out when a chat waits for an approval or an answer, or a turn failed, for longer than the delay; when the wait ends, an unsent message is cancelled. It holds the chat title and the request, not the conversation. A Reply answer comes back to that chat: a matching question gets answered, otherwise the text waits in the chat's queue. Actions cannot be approved from Telegram."))
                .font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: bridge.enabled) { if bridge.enabled { await bridge.check() } }
    }
}
