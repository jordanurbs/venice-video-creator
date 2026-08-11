import Foundation

/// Fits an agent conversation into a token budget so inference calls don't exceed
/// the model's context window.
///
/// There's no local tokenizer, so counts are estimated: ~4 characters per token
/// for text, and inline base64 images counted by their encoded length (Venice's
/// OpenAI-compatible endpoint counts inline image data toward the text budget —
/// that's what overflows on image-heavy chats).
enum ContextBudget {
    static let charsPerToken = 4
    /// Headroom for system prompt drift, tool schemas, and estimation error.
    static let safetyMargin = 8_000
    /// Max request-body size worth shipping: Venice rejects oversized
    /// chat/completions bodies with HTTP 413 no matter how large the model's
    /// token window is. Inline base64 images are what get a payload here —
    /// ~3 MB of message content leaves room for the system prompt and tool
    /// schemas under a typical 4-5 MB server cap.
    static let maxPayloadBytes = 3_000_000

    struct Result {
        var kept: [AnthropicMessage]
        /// Oldest-first messages removed from the window (folded into a recap).
        var evicted: [AnthropicMessage]
        var strippedImages: Bool
    }

    static func estimateTokens(_ message: AnthropicMessage) -> Int {
        estimateTokens(message.content)
    }

    static func estimateTokens(_ content: [[String: Any]]) -> Int {
        content.reduce(0) { $0 + blockChars($1) } / charsPerToken + 4
    }

    static func estimateTokens(text: String) -> Int { text.count / charsPerToken + 1 }

    private static func blockChars(_ block: [String: Any]) -> Int {
        switch block["type"] as? String {
        case "text":
            return (block["text"] as? String)?.count ?? 0
        case "image":
            return ((block["source"] as? [String: Any])?["data"] as? String)?.count ?? 0
        case "tool_use":
            let name = (block["name"] as? String)?.count ?? 0
            let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:]).count) ?? 0
            return name + input
        case "tool_result":
            return (block["content"] as? [[String: Any]])?.reduce(0) { $0 + blockChars($1) } ?? 0
        default:
            return (try? JSONSerialization.data(withJSONObject: block).count) ?? 0
        }
    }

    private static func hasToolResult(_ m: AnthropicMessage) -> Bool {
        m.content.contains { $0["type"] as? String == "tool_result" }
    }

    private static func hasToolUse(_ m: AnthropicMessage) -> Bool {
        m.content.contains { $0["type"] as? String == "tool_use" }
    }

    /// Replaces inline image blocks with a short placeholder — including images
    /// nested inside `tool_result` content arrays (inspect_media, qa_shot,
    /// frame grabs, color scopes all deliver their images there; a top-level-only
    /// walk misses the bulk of a production run's payload).
    static func stripImages(from content: [[String: Any]]) -> (content: [[String: Any]], removed: Int) {
        var removed = 0
        let out: [[String: Any]] = content.map { block in
            switch block["type"] as? String {
            case "image":
                removed += 1
                return ["type": "text", "text": "[image omitted to fit context — use inspect_media to re-view]"]
            case "tool_result":
                guard let nested = block["content"] as? [[String: Any]] else { return block }
                let (newNested, nestedRemoved) = stripImages(from: nested)
                guard nestedRemoved > 0 else { return block }
                removed += nestedRemoved
                var updated = block
                updated["content"] = newNested
                return updated
            default:
                return block
            }
        }
        return (out, removed)
    }

    /// Per-block ceiling applied when truncating oversized text. ~8k chars
    /// (~2k tokens) keeps the useful head of a tool result while capping the
    /// worst case: 6 recent turns × a few blocks each stays well under 1 MB.
    static let maxTextBlockChars = 8_000

    /// Truncates oversized text blocks — top-level, nested in `tool_result`
    /// content, and giant `tool_use` inputs (e.g. base64 passed as a tool
    /// argument). Images can't be the only strippable weight: a 63 MB body of
    /// tool-result text sails past an image-only strip and dead-ends the chat.
    static func truncateOversizedText(
        in content: [[String: Any]], maxChars: Int = maxTextBlockChars
    ) -> (content: [[String: Any]], truncated: Int) {
        var truncated = 0
        func clip(_ s: String) -> String {
            "\(s.prefix(maxChars))\n[…truncated \(s.count - maxChars) chars to fit context — re-run the tool for full output]"
        }
        let out: [[String: Any]] = content.map { block in
            switch block["type"] as? String {
            case "text":
                guard let s = block["text"] as? String, s.count > maxChars else { return block }
                truncated += 1
                return ["type": "text", "text": clip(s)]
            case "tool_use":
                let inputBytes = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:]).count) ?? 0
                guard inputBytes > maxChars else { return block }
                truncated += 1
                var updated = block
                updated["input"] = ["_omitted": "input truncated to fit context (\(inputBytes) bytes)"]
                return updated
            case "tool_result":
                guard let nested = block["content"] as? [[String: Any]] else { return block }
                let (newNested, n) = truncateOversizedText(in: nested, maxChars: maxChars)
                guard n > 0 else { return block }
                truncated += n
                var updated = block
                updated["content"] = newNested
                return updated
            default:
                return block
            }
        }
        return (out, truncated)
    }

    /// Applies `truncateOversizedText` to every message.
    static func truncateAllOversizedText(
        from messages: [AnthropicMessage], maxChars: Int = maxTextBlockChars
    ) -> (messages: [AnthropicMessage], truncated: Int) {
        var truncated = 0
        let out = messages.map { m -> AnthropicMessage in
            let (content, n) = truncateOversizedText(in: m.content, maxChars: maxChars)
            truncated += n
            return n > 0 ? AnthropicMessage(role: m.role, content: content) : m
        }
        return (out, truncated)
    }

    /// Strips every inline image from every message. Used as the final
    /// escape hatch when a serialized request body is still over the byte cap.
    /// Placeholders are text blocks, so tool_use/tool_result pairing survives.
    static func stripAllImages(from messages: [AnthropicMessage]) -> (messages: [AnthropicMessage], removed: Int) {
        var removed = 0
        let out = messages.map { m -> AnthropicMessage in
            let (content, r) = stripImages(from: m.content)
            removed += r
            return r > 0 ? AnthropicMessage(role: m.role, content: content) : m
        }
        return (out, removed)
    }

    /// Fits `messages` into `budget` tokens. First strips images from all but the
    /// most recent `keepRecent` turns, then evicts whole turns from the front —
    /// keeping `tool_use`/`tool_result` pairs together and never leaving an orphan
    /// tool result at the front.
    static func fit(messages: [AnthropicMessage], budget: Int, keepRecent: Int) -> Result {
        var kept = messages
        var evicted: [AnthropicMessage] = []
        var strippedImages = false

        func total() -> Int { kept.reduce(0) { $0 + estimateTokens($1) } }

        if total() > budget {
            let stripUntil = max(0, kept.count - keepRecent)
            for i in 0..<stripUntil {
                let (newContent, removed) = stripImages(from: kept[i].content)
                if removed > 0 {
                    kept[i] = AnthropicMessage(role: kept[i].role, content: newContent)
                    strippedImages = true
                }
            }
        }

        while total() > budget && kept.count > keepRecent {
            let removed = kept.removeFirst()
            evicted.append(removed)
            // Keep an assistant tool_use turn together with its tool_result reply.
            if hasToolUse(removed), let next = kept.first, hasToolResult(next), kept.count > keepRecent {
                evicted.append(kept.removeFirst())
            }
        }
        // Never start the window with an orphan tool result (no preceding tool_use).
        while let first = kept.first, hasToolResult(first), kept.count > 1 {
            evicted.append(kept.removeFirst())
        }

        // Still over budget with only the recent window left: the recent turns
        // themselves carry the weight (typically inline reference images during
        // a production run). Strip their images too, oldest first — otherwise
        // the request ships over budget and Venice rejects it (HTTP 413), and
        // every retry re-sends the same oversized body.
        if total() > budget {
            for i in kept.indices {
                guard total() > budget else { break }
                let (newContent, removed) = stripImages(from: kept[i].content)
                if removed > 0 {
                    kept[i] = AnthropicMessage(role: kept[i].role, content: newContent)
                    strippedImages = true
                }
            }
        }

        // Final pass: images are gone and the window is still over budget —
        // the weight is oversized TEXT (giant tool results, base64 riding in
        // tool_use inputs). Truncate those blocks; otherwise `fit` returns an
        // over-budget list with no failure signal and the request dead-ends
        // at the byte gate ("conversation too large, start a new chat").
        if total() > budget {
            for i in kept.indices {
                guard total() > budget else { break }
                let (newContent, truncated) = truncateOversizedText(in: kept[i].content)
                if truncated > 0 {
                    kept[i] = AnthropicMessage(role: kept[i].role, content: newContent)
                }
            }
        }

        return Result(kept: kept, evicted: evicted, strippedImages: strippedImages)
    }

    /// Flattens evicted messages into a plain transcript for the summarizer.
    static func transcript(for messages: [AnthropicMessage]) -> String {
        var lines: [String] = []
        for m in messages {
            var parts: [String] = []
            for block in m.content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty { parts.append(t) }
                case "image":
                    parts.append("[image]")
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    parts.append("(called \(name))")
                case "tool_result":
                    let text = (block["content"] as? [[String: Any]])?
                        .compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
                    parts.append("(result: \(text.prefix(500)))")
                default:
                    break
                }
            }
            guard !parts.isEmpty else { continue }
            lines.append("\(m.role.rawValue.uppercased()): \(parts.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }
}
