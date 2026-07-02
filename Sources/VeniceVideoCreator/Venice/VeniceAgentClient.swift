import Foundation

/// Agent client that streams from Venice's OpenAI-compatible `/chat/completions`.
///
/// The rest of the agent (AgentService loop, ToolExecutor, message storage) is
/// modeled on Anthropic's message/tool shapes. This client is the adapter: it
/// converts those shapes to OpenAI on the way out and maps the OpenAI streaming
/// response back into `AnthropicStreamEvent` on the way in.
struct VeniceAgentClient: AgentClient {
    let apiKey: String
    /// Venice text model id (e.g. a Qwen/Llama variant with function calling).
    let model: String
    var maxTokens: Int = 8192
    /// Optional Venice character persona slug (applied via venice_parameters).
    var characterSlug: String? = nil

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AgentClientError.unauthenticated }

        let body = VeniceChatRequest.build(
            model: model, maxTokens: maxTokens, system: system, tools: tools, messages: messages,
            characterSlug: characterSlug
        )
        let api = VeniceAPI(apiKey: apiKey)
        let request = api.makeRequest(
            path: "chat/completions",
            accept: "text/event-stream",
            body: try JSONSerialization.data(withJSONObject: body, options: [])
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var raw = ""
            for try await line in bytes.lines { raw += line + "\n" }
            throw AgentClientError.from(status: http.statusCode, body: raw)
        }

        try await OpenAISSE.parse(bytes: bytes, continuation: continuation)
    }
}

// MARK: - OpenAI streaming parser

/// Parses an OpenAI-compatible `chat.completions` SSE stream into the
/// Anthropic-shaped events the agent loop consumes.
enum OpenAISSE {
    private struct ToolAccumulator {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var tools: [Int: ToolAccumulator] = [:]
        var finished = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let delta = choice["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        let index = call["index"] as? Int ?? 0
                        var acc = tools[index] ?? ToolAccumulator()
                        if let id = call["id"] as? String, !id.isEmpty { acc.id = id }
                        if let function = call["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty { acc.name = name }
                            if let args = function["arguments"] as? String { acc.arguments += args }
                        }
                        tools[index] = acc
                    }
                }
            }

            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                flushTools(tools, continuation: continuation)
                continuation.yield(.messageStop(stopReason: Self.stopReason(from: reason, hadTools: !tools.isEmpty)))
                finished = true
                break
            }
        }

        if !finished {
            flushTools(tools, continuation: continuation)
            continuation.yield(.messageStop(stopReason: tools.isEmpty ? .endTurn : .toolUse))
        }
    }

    private static func flushTools(
        _ tools: [Int: ToolAccumulator],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) {
        for index in tools.keys.sorted() {
            let acc = tools[index]!
            guard !acc.id.isEmpty || !acc.name.isEmpty else { continue }
            let id = acc.id.isEmpty ? "call_\(index)" : acc.id
            let json = acc.arguments.isEmpty ? "{}" : acc.arguments
            continuation.yield(.toolUseComplete(id: id, name: acc.name, inputJSON: json))
        }
    }

    private static func stopReason(from reason: String, hadTools: Bool) -> AnthropicStopReason {
        switch reason {
        case "tool_calls": return .toolUse
        case "length": return .maxTokens
        case "stop": return hadTools ? .toolUse : .endTurn
        default: return hadTools ? .toolUse : .endTurn
        }
    }
}

// MARK: - Request body builder (Anthropic shape -> OpenAI shape)

enum VeniceChatRequest {
    static func build(
        model: String,
        maxTokens: Int,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        characterSlug: String? = nil
    ) -> [String: Any] {
        var openAIMessages: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            openAIMessages.append(contentsOf: convert(message))
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": openAIMessages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ],
                ]
            }
        }
        if let slug = characterSlug, !slug.isEmpty {
            body["venice_parameters"] = [
                "character_slug": slug,
                "include_venice_system_prompt": false,
            ]
        }
        return body
    }

    /// Convert one Anthropic-shaped message into one or more OpenAI messages.
    private static func convert(_ message: AnthropicMessage) -> [[String: Any]] {
        let role = message.role == .user ? "user" : "assistant"
        var textParts: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []
        var toolResultMessages: [[String: Any]] = []

        for block in message.content {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String { textParts.append(["type": "text", "text": text]) }
            case "image":
                if let source = block["source"] as? [String: Any],
                   let mediaType = source["media_type"] as? String,
                   let dataString = source["data"] as? String {
                    textParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mediaType);base64,\(dataString)"],
                    ])
                }
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let argsString = (try? String(
                    data: JSONSerialization.data(withJSONObject: input), encoding: .utf8
                )) ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": argsString],
                ])
            case "tool_result":
                let toolUseId = block["tool_use_id"] as? String ?? ""
                let content = block["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                toolResultMessages.append([
                    "role": "tool",
                    "tool_call_id": toolUseId,
                    "content": text.isEmpty ? "(no text content)" : text,
                ])
            default:
                break
            }
        }

        var out: [[String: Any]] = []

        // Assistant turns may carry text and/or tool calls in a single message.
        if role == "assistant" {
            if !textParts.isEmpty || !toolCalls.isEmpty {
                var assistant: [String: Any] = ["role": "assistant"]
                let plainText = textParts.compactMap { $0["text"] as? String }.joined()
                assistant["content"] = plainText
                if !toolCalls.isEmpty { assistant["tool_calls"] = toolCalls }
                out.append(assistant)
            }
        } else {
            // User turns: text/image content as a multi-part message, plus any
            // tool result messages (which must each be their own `tool` message).
            if !textParts.isEmpty {
                out.append(["role": "user", "content": textParts])
            }
            out.append(contentsOf: toolResultMessages)
        }
        return out
    }
}
