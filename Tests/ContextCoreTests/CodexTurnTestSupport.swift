import ContextCore
import Testing

/// Checks the wire layout before returning the untouched user input, including any inline notes or attachment paths.
func codexTurnUserText(_ request: JSONValue) throws -> String {
    let params = request["params"]
    let input = params["input"].array
    try #require(request["method"].string == "turn/start")
    try #require(input.count == 2)

    let appContext = input[1]
    let model = params["model"].string ?? ""
    let expectedContexts = AppLanguage.allCases.map { language in
        JSONValue.object([
            "type": .string("text"),
            "text": .string(AgentModelContext.instructions(model: model, provider: .codex, language: language)),
            "text_elements": .array([])
        ])
    }
    try #require(expectedContexts.contains(appContext))

    let userInput = input[0]
    try #require(userInput["type"].string == "text")
    try #require(userInput["text_elements"] == .array([]))
    return try #require(userInput["text"].string)
}
