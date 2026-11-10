import AppKit
import SwiftUI
import ContextCore

@MainActor enum ProjectVerificationWindow {
    private static var windows: [String: NSWindow] = [:]
    static func show(path: String) {
        if let window = windows[path] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L10n.text("Проверки проекта", "Project verification")
        window.contentView = NSHostingView(rootView: ProjectVerificationView(path: path))
        window.center()
        windows[path] = window
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ProjectVerificationView: View {
    let path: String
    @State private var status: VerificationStatus?
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("Общая очередь проверок", "Shared verification queue")).font(.headline)
                Spacer()
                Button(L10n.text("Обновить", "Refresh")) { refresh() }
            }
            Text(URL(fileURLWithPath: path).lastPathComponent).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.secondary) }
            if let status {
                if status.tasks.isEmpty {
                    Text(L10n.text("Задач в очереди пока нет.", "No tasks in the queue yet."))
                }
                List(status.tasks) { task in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title ?? task.id).fontWeight(.medium)
                        Text(VerificationStatus.title(task.status)).foregroundStyle(.secondary)
                        if let blocker = task.blocker { Text(blocker).font(.caption).textSelection(.enabled) }
                    }.padding(.vertical, 4)
                }
                if let batch = status.batches?.last {
                    HStack {
                        Text(L10n.text("Последняя партия: ", "Latest batch: ") + VerificationStatus.title(batch.status))
                        Spacer()
                        Text(L10n.text("Ожидание: \(batch.waitingSeconds) с", "Waiting: \(batch.waitingSeconds)s"))
                        if let seconds = batch.runningSeconds {
                            Text(L10n.text("Проверка: \(seconds) с", "Verification: \(seconds)s"))
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(L10n.text("Результат проверки относится к зафиксированным изменениям. Публикация и проверка в приложении учитываются отдельно.",
                           "Verification applies to fixed changes. Publication and app verification are tracked separately."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 460, minHeight: 300).onAppear { refresh() }
    }
    private func refresh() {
        let file = URL(fileURLWithPath: path).appendingPathComponent(".build/verification/status.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4_000_000 else {
                status = nil
                issue = L10n.text("Файл состояния слишком большой.", "The status file is too large.")
                return
            }
            status = try VerificationStatus.decode(Data(contentsOf: file))
            issue = nil
        } catch {
            status = nil
            issue = FileManager.default.fileExists(atPath: file.path)
                ? L10n.text("Не удалось прочитать состояние очереди.", "Could not read the queue status.")
                : L10n.text("Очередь ещё не создана. Она появится после первой заявки агента.", "The queue has not been created yet. It appears after the first agent submission.")
        }
    }
}
