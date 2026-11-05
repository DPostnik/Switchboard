import Foundation
import AgentContract

// Mac side of phone questions. Kept out of MobileRemote.swift, which the iOS target compiles without AgentContract.
extension RemoteInteraction {
    /// The phone form of a pending request; nil for approvals. Never answerable when anything had to be cut.
    public init?(_ interaction: AgentInteraction) {
        var lossy = false
        func clip(_ text: String, _ limit: Int) -> String {
            guard text.count > limit else { return text }
            lossy = true; return String(text.prefix(limit))
        }
        func fields(_ list: [AgentInteraction.Field]) -> [RemoteQuestion] {
            if list.count > Self.questionLimit { lossy = true }
            return list.prefix(Self.questionLimit).map { field in
                if field.options.count > Self.optionLimit { lossy = true }
                return RemoteQuestion(id: clip(field.id, Self.textLimit), header: field.header.map { clip($0, Self.headerLimit) },
                    text: clip(field.text, Self.textLimit),
                    options: field.options.prefix(Self.optionLimit).map {
                        RemoteQuestionOption(label: clip($0.label, Self.labelLimit), description: $0.description.map { clip($0, Self.descriptionLimit) },
                                             preview: $0.preview.map { clip($0, Self.previewLimit) })
                    }, secret: field.secret ? true : nil, required: field.required)
            }
        }
        var reason: MacOnly?
        let id = interaction.id.uuidString
        switch interaction.kind {
        case .approval: return nil
        case .questions(let list):
            self.init(id: id, kind: .questions, questions: fields(list), canAnswer: true, canDecline: false)
        case .form(let message, let list):
            self.init(id: id, kind: .form, message: clip(message, Self.messageLimit), questions: fields(list), canAnswer: true, canDecline: true)
        case .link(let message, _):
            self.init(id: id, kind: .link, message: clip(message, Self.messageLimit), questions: [], canAnswer: false, canDecline: true)
            reason = .link
        case .unsupported(let message):
            self.init(id: id, kind: .unsupported, message: clip(message, Self.messageLimit), questions: [], canAnswer: false, canDecline: true)
            reason = .unsupported
        }
        // Over the budget: drop the explanations first, then shorten what is left. Either way the phone cannot answer.
        if characters > Self.characterBudget {
            lossy = true
            for index in questions.indices {
                questions[index].options = questions[index].options.map { RemoteQuestionOption(label: $0.label) }
            }
        }
        if characters > Self.characterBudget {
            message = message.map { String($0.prefix(500)) }
            for index in questions.indices {
                questions[index].text = String(questions[index].text.prefix(500))
                questions[index].id = String(questions[index].id.prefix(500))
                questions[index].options = questions[index].options.map { RemoteQuestionOption(label: String($0.label.prefix(100))) }
            }
        }
        if reason == nil, questions.contains(where: { $0.secret == true }) { reason = .secret }
        if reason == nil, lossy { reason = .tooLarge }
        if let reason { canAnswer = false; macOnly = reason.rawValue }
    }
}
