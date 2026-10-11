import Foundation

// LocalMLX providers — adapt LocalModelHost to the app's two provider protocols.
//
// [T-nabla-local-mlx-provider] A real `ProviderType.localMLX`: instances are added through Add
// Provider like any vendor, and the model list is the library folder (see fetchModelsForInstance).
//
// Text only for now: tool definitions are not forwarded to local models yet. Small models with large
// tool schemas are a known weak spot, and tool results are rendered into the transcript as text so the
// agent can still read them.

/// Plain chat / completion provider (title generation, quick tasks, non-agent paths).
struct LocalMLXProvider: LLMProvider {
    var name: String { "On-Device" }
    var model: LLMModel

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        var text = ""
        var usage: LLMUsage?
        for try await chunk in try await streamMessage(messages: messages, systemPrompt: systemPrompt,
                                                       maxTokens: maxTokens, temperature: temperature) {
            switch chunk {
            case .text(let t): text += t
            case .usage(let u): usage = u
            default: break
            }
        }
        return LLMResponse(text: text, stopReason: "end_turn", usage: usage)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let history = messages.map { (role: $0.role == .assistant ? "assistant" : "user", text: $0.content) }
        let id = model.id
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    cont.yield(.started)
                    try await LocalModelHost.shared.stream(
                        modelId: id, system: systemPrompt, history: history,
                        maxTokens: maxTokens, temperature: Float(temperature ?? 0.6), thinking: false
                    ) { ev in
                        switch ev {
                        case .text(let t): cont.yield(.text(t))
                        case .usage(let i, let o, _):
                            cont.yield(.usage(LLMUsage(inputTokens: i, outputTokens: o,
                                                       cacheCreationInputTokens: nil, cacheReadInputTokens: nil)))
                        case .done: cont.yield(.finished(stopReason: "end_turn"))
                        default: break
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Agent-loop provider. Tool results are rendered into the transcript as text so the model can read
/// them even before native tool calling is enabled for local models.
struct LocalMLXAgentProvider: AgentProvider {
    var name: String { "On-Device" }
    let model: LLMModel
    var defaultMaxTokens: Int { 2048 }

    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?,
                                   tools: [AgentToolDefinition], maxTokens: Int,
                                   thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let history: [(role: String, text: String)] = messages.map { m in
            let text = m.parts.map { part -> String in
                switch part {
                case .text(let t): return t
                case .toolUse(_, let name, let input, _):
                    let args = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return "[called \(name) \(args)]"
                case .toolResult(_, let name, let content, let isError, _, _, _, _, _):
                    return "[\(name) \(isError ? "error" : "result")]\n\(content)"
                case .imageData: return "[image]"
                }
            }.joined(separator: "\n")
            return (role: m.role == .assistant ? "assistant" : "user", text: text)
        }
        let id = model.id
        let thinking = thinkingLevel != .off
        let budget = min(maxTokens, thinking ? 4096 : 2048)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    cont.yield(.contentBlockStart(.text))
                    cont.yield(.responseModel(id))
                    try await LocalModelHost.shared.stream(
                        modelId: id, system: systemPrompt, history: history,
                        maxTokens: budget, temperature: 0.6, thinking: thinking
                    ) { ev in
                        switch ev {
                        case .text(let t): cont.yield(.textDelta(t))
                        case .thinking(let t): cont.yield(.thinkingDelta(t))
                        case .usage(let i, let o, _):
                            cont.yield(.usage(LLMUsage(inputTokens: i, outputTokens: o,
                                                       cacheCreationInputTokens: nil, cacheReadInputTokens: nil)))
                        case .done(let hit): cont.yield(.done(stopReason: hit ? .maxTokens : .endTurn))
                        case .cache: break
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

extension LLMModel {
    /// The models in the on-device library, as picker entries.
    ///
    /// Enumerated from disk, so the list is whatever the user actually has (LoopLab models copied
    /// across, or a folder dropped into Files). Empty until something is in the library — the Local
    /// Inference settings page is where that changes.
    static var allLocalMLX: [LLMModel] {
        LocalModelStore.installed().map { m in
            LLMModel(id: m.id, displayName: "\(m.name) (on-device)", provider: "localMLX")
        }
    }
}
