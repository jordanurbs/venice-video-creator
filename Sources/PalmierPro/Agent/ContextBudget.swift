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

    /// Replaces inline image blocks with a short placeholder.
    private static func stripImages(from content: [[String: Any]]) -> (content: [[String: Any]], removed: Int) {
        var removed = 0
        let out: [[String: Any]] = content.map { block in
            guard block["type"] as? String == "image" else { return block }
            removed += 1
            return ["type": "text", "text": "[image omitted to fit context]"]
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
