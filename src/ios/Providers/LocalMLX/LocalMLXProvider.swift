import Foundation

// LocalMLX providers — adapt LocalModelHost to the app's two provider protocols.
//
// [T-nabla-local-mlx-provider] A real `ProviderType.localMLX`: instances are added through Add
// Provider like any vendor, and the model list is the library folder (see fetchModelsForInstance).
//
// Capabilities are declared per model from its own config rather than assumed: a vision model that is
// advertised as text-only is handed an image it cannot see, and the app then decides the turn is blind
// and routes it through the screenshot/Vision-Group path — which is why a multimodal model asked to
// describe a photo answered with a `shell_execute` call. The modality override is what tells the app to
// pass native pixels through instead.

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
        let history = messages.map { LocalTurn(role: $0.role == .assistant ? "assistant" : "user",
                                               text: $0.content) }
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

/// Agent-loop provider learning a local model's own sampling settings and modality.
struct LocalMLXAgentProvider: AgentProvider {
    var name: String { "On-Device" }
    let model: LLMModel
    var defaultMaxTokens: Int { 4096 }

    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?,
                                   tools: [AgentToolDefinition], maxTokens: Int,
                                   thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        // Parts → structured turns, the way the other providers send them: images as images, tool calls
        // as assistant tool calls, tool results as tool-role messages. [T-nabla-local-mlx-tools]
        var history: [LocalTurn] = []
        for m in messages {
            var images: [Data] = []
            var texts: [String] = []
            var calls: [LocalToolCall] = []
            var results: [LocalTurn] = []
            for part in m.parts {
                switch part {
                case .text(let t):
                    texts.append(t)
                case .imageData(let data, _, _):
                    images.append(data)
                case .toolUse(let callId, let name, let input, _):
                    let json = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    calls.append(LocalToolCall(id: callId, name: name, argumentsJSON: json))
                case .toolResult(let callId, let name, let content, let isError, let imageData, _, _, _, _):
                    // An image a tool returned (a screenshot, read_image) rides along with its result.
                    var resultImages: [Data] = []
                    if let imageData { resultImages.append(imageData) }
                    results.append(LocalTurn(role: "tool", text: isError ? "Error: \(content)" : content,
                                             images: resultImages, toolCallId: callId, toolName: name))
                }
            }
            let text = texts.joined(separator: "\n")
            if m.role == .assistant {
                history.append(LocalTurn(role: "assistant", text: text, toolCalls: calls))
            } else {
                // Tool results come back inside a user message; they become their own tool-role turns.
                history.append(contentsOf: results)
                if !text.isEmpty || !images.isEmpty {
                    history.append(LocalTurn(role: "user",
                                             text: text.isEmpty ? "Describe this image." : text,
                                             images: images))
                }
            }
        }

        // The schemas, in the OpenAI function shape MLX's ToolSpec uses (the same shape the OpenAI
        // provider sends). The model's own template decides how they are rendered.
        let toolSpecs: [[String: any Sendable]]? = tools.isEmpty ? nil : tools.map { tool in
            var properties: [String: any Sendable] = [:]
            for (name, param) in tool.parameters {
                var prop: [String: any Sendable] = ["type": param.type.rawValue, "description": param.description]
                if let e = param.enumValues { prop["enum"] = e }
                properties[name] = prop
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": ["type": "object", "properties": properties,
                                   "required": tool.required] as [String: any Sendable],
                ] as [String: any Sendable],
            ]
        }

        let id = model.id
        let thinking = thinkingLevel.isEnabled && (model.supportsReasoning ?? false)
        let budget = min(maxTokens, thinking ? 8192 : 4096)
        // nil temperature = the model's own generation_config decides (see LocalSampling: this is also
        // where the expensive full-vocabulary top-p sort is avoided for small models).
        // nil = let the checkpoint's own generation_config decide.
        let temperature: Float? = nil
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    cont.yield(.contentBlockStart(.text))
                    cont.yield(.responseModel(id))
                    let calledTools = ToolCallTracker()
                    try await LocalModelHost.shared.stream(
                        modelId: id, system: systemPrompt, history: history,
                        maxTokens: budget, temperature: temperature, thinking: thinking,
                        tools: toolSpecs
                    ) { ev in
                        switch ev {
                        case .text(let t): cont.yield(.textDelta(t))
                        case .thinking(let t): cont.yield(.thinkingDelta(t))
                        case .toolCall(let callId, let name, let json):
                            // Same events a cloud provider emits, so the app's loop executes the tool,
                            // shows it in the tool sheet, and sends the result back — no parallel path.
                            let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
                            cont.yield(.contentBlockStart(.toolUse(id: callId, name: name)))
                            cont.yield(.toolInputDelta(name: name, accumulated: json))
                            cont.yield(.toolCallComplete(id: callId, name: name, args: args, metadata: nil))
                            calledTools.mark()
                        case .usage(let i, let o, _):
                            cont.yield(.usage(LLMUsage(inputTokens: i, outputTokens: o,
                                                       cacheCreationInputTokens: nil, cacheReadInputTokens: nil)))
                        case .done(let hit):
                            cont.yield(.done(stopReason: hit ? .maxTokens
                                                 : (calledTools.any ? .toolUse : .endTurn)))
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
    /// The models in the on-device library, as picker entries — with each model's real capabilities.
    ///
    /// [T-nabla-local-mlx-capabilities] `modalityOverride`, `contextWindow`, `supportsReasoning` and the
    /// sampling defaults are all read from the checkpoint's own config.json. They are not decoration:
    /// `capabilities.supportedModalities.contains(.imageInput)` is what decides whether an attached photo
    /// is sent as pixels or replaced by a "use the vision tool" instruction.
    static var allLocalMLX: [LLMModel] {
        LocalModelStore.installed().map { m in
            // `supportsReasoning` is the switch that makes the app offer a thinking level at all; the
            // sampler settings themselves travel with the engine (see LocalSampling), because they are
            // a property of the checkpoint rather than of a user-facing model entry.
            return LLMModel(
                id: m.id,
                displayName: "\(m.name) (on-device)",
                provider: "localMLX",
                modalityOverride: m.kind == .vision ? .vision : .textOnly,
                contextWindow: m.contextLength,
                maxOutputTokens: 8192,
                supportsReasoning: m.thinkingCapable)
        }
    }
}

/// Whether a turn ended by calling tools — which decides the stop reason the agent loop acts on.
private final class ToolCallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func mark() { lock.lock(); called = true; lock.unlock() }
    var any: Bool { lock.lock(); defer { lock.unlock() }; return called }
}
