import Foundation
import Testing
@testable import VeniceVideoCreator

/// Context/payload budgeting — especially the HTTP 413 guard: inline images
/// in RECENT turns must also be stripped when they alone exceed the budget.
@Suite("ContextBudget")
struct ContextBudgetTests {

    private func textMessage(_ role: AnthropicMessage.Role, _ text: String) -> AnthropicMessage {
        AnthropicMessage(role: role, content: [["type": "text", "text": text]])
    }

    private func imageMessage(_ role: AnthropicMessage.Role, chars: Int) -> AnthropicMessage {
        AnthropicMessage(role: role, content: [[
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": String(repeating: "A", count: chars)],
        ]])
    }

    @Test func underBudgetIsUntouched() {
        let msgs = [textMessage(.user, "hi"), textMessage(.assistant, "hello")]
        let result = ContextBudget.fit(messages: msgs, budget: 10_000, keepRecent: 6)
        #expect(result.kept.count == 2)
        #expect(result.evicted.isEmpty)
        #expect(!result.strippedImages)
    }

    @Test func oldTurnsEvictBeforeRecentOnes() {
        var msgs: [AnthropicMessage] = []
        for i in 0..<10 { msgs.append(textMessage(.user, String(repeating: "x", count: 4_000) + "\(i)")) }
        let result = ContextBudget.fit(messages: msgs, budget: 5_000, keepRecent: 4)
        #expect(result.kept.count == 4)
        #expect(result.evicted.count == 6)
    }

    @Test func imagesInRecentTurnsAreStrippedWhenTheyAloneExceedBudget() {
        // 6 recent turns, each carrying a ~400KB image: no amount of eviction
        // helps because keepRecent floors the window — pre-fix this shipped an
        // oversized body and Venice 413'd it.
        var msgs: [AnthropicMessage] = []
        for _ in 0..<6 { msgs.append(imageMessage(.user, chars: 400_000)) }
        let result = ContextBudget.fit(messages: msgs, budget: 50_000, keepRecent: 6)
        #expect(result.kept.count == 6)
        #expect(result.strippedImages)
        let total = result.kept.reduce(0) { $0 + ContextBudget.estimateTokens($1) }
        #expect(total <= 50_000)
        // Placeholders remain so the model knows an image was there.
        let hasPlaceholder = result.kept.contains { m in
            m.content.contains { ($0["text"] as? String)?.contains("image omitted") == true }
        }
        #expect(hasPlaceholder)
    }

    private func toolResultImageMessage(chars: Int, toolUseId: String = "t1") -> AnthropicMessage {
        AnthropicMessage(role: .user, content: [[
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": [
                ["type": "text", "text": "frame grab"],
                [
                    "type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": String(repeating: "B", count: chars)],
                ],
            ] as [[String: Any]],
            "is_error": false,
        ]])
    }

    @Test func imagesNestedInToolResultsAreStripped() {
        // Production runs deliver most images inside tool_result content
        // (inspect_media, qa_shot, frame grabs). Pre-fix, stripImages only
        // matched top-level image blocks: the budgeter counted the weight,
        // removed nothing, and shipped the oversized body anyway (HTTP 413).
        var msgs: [AnthropicMessage] = []
        for i in 0..<6 { msgs.append(toolResultImageMessage(chars: 400_000, toolUseId: "t\(i)")) }
        let result = ContextBudget.fit(messages: msgs, budget: 50_000, keepRecent: 6)
        #expect(result.strippedImages)
        let total = result.kept.reduce(0) { $0 + ContextBudget.estimateTokens($1) }
        #expect(total <= 50_000)
        // tool_result blocks survive (pairing invariant) with placeholder text inside.
        let stillToolResults = result.kept.allSatisfy { m in
            m.content.contains { $0["type"] as? String == "tool_result" }
        }
        #expect(stillToolResults)
    }

    @Test func stripAllImagesRemovesEveryInlineImage() {
        let msgs = [
            imageMessage(.user, chars: 100_000),
            toolResultImageMessage(chars: 100_000),
            textMessage(.assistant, "ok"),
        ]
        let (stripped, removed) = ContextBudget.stripAllImages(from: msgs)
        #expect(removed == 2)
        let hasImage = stripped.contains { m in
            m.content.contains { block in
                if block["type"] as? String == "image" { return true }
                if let nested = block["content"] as? [[String: Any]] {
                    return nested.contains { $0["type"] as? String == "image" }
                }
                return false
            }
        }
        #expect(!hasImage)
    }

    @Test func serializedBodyStaysUnderByteCapWithManyImageToolResults() throws {
        // Definition-of-done scenario: 20 image-bearing tool results in history
        // must not produce a request body over the client byte gate.
        var msgs: [AnthropicMessage] = []
        for i in 0..<20 {
            msgs.append(AnthropicMessage(role: .assistant, content: [[
                "type": "tool_use", "id": "t\(i)", "name": "inspect_media", "input": ["mediaRef": "m\(i)"],
            ]]))
            msgs.append(toolResultImageMessage(chars: 400_000, toolUseId: "t\(i)"))
        }
        let body = try VeniceAgentClient.serializedBody(
            model: "test-model", maxTokens: 8192, system: "sys", tools: [],
            messages: msgs, characterSlug: nil
        )
        #expect(body.count <= VeniceAgentClient.maxRequestBodyBytes)
    }

    @Test func serializedBodyTruncatesWhenTextAloneIsOversized() throws {
        // No images to strip — an all-text conversation over the cap used to
        // throw payloadTooLarge and dead-end the chat ("start a new chat").
        // Now the text-truncation escape hatch shrinks it under the gate.
        let msgs = (0..<10).map { _ in textMessage(.user, String(repeating: "x", count: 600_000)) }
        let body = try VeniceAgentClient.serializedBody(
            model: "test-model", maxTokens: 8192, system: "sys", tools: [],
            messages: msgs, characterSlug: nil
        )
        #expect(body.count <= VeniceAgentClient.maxRequestBodyBytes)
    }

    private func toolResultTextMessage(chars: Int, toolUseId: String = "t1") -> AnthropicMessage {
        AnthropicMessage(role: .user, content: [[
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": [["type": "text", "text": String(repeating: "y", count: chars)]] as [[String: Any]],
            "is_error": false,
        ]])
    }

    @Test func oversizedTextInRecentToolResultsIsTruncated() {
        // The 63MB dead-end scenario: recent turns carry giant TEXT tool
        // results (no images to strip). fit must truncate them to budget
        // instead of returning an over-budget window with no failure signal.
        var msgs: [AnthropicMessage] = []
        for i in 0..<6 { msgs.append(toolResultTextMessage(chars: 2_000_000, toolUseId: "t\(i)")) }
        let result = ContextBudget.fit(messages: msgs, budget: 50_000, keepRecent: 6)
        let total = result.kept.reduce(0) { $0 + ContextBudget.estimateTokens($1) }
        #expect(total <= 50_000)
        // tool_result pairing survives, with a truncation note inside.
        let allToolResults = result.kept.allSatisfy { m in
            m.content.contains { $0["type"] as? String == "tool_result" }
        }
        #expect(allToolResults)
        let hasNote = result.kept.contains { m in
            m.content.contains { block in
                ((block["content"] as? [[String: Any]])?.contains {
                    ($0["text"] as? String)?.contains("truncated") == true
                }) == true
            }
        }
        #expect(hasNote)
    }

    @Test func oversizedToolUseInputIsTruncated() {
        // e.g. import_media with megabytes of base64 in source.bytes — the
        // input rides every subsequent request inside the arguments string.
        let msgs = [AnthropicMessage(role: .assistant, content: [[
            "type": "tool_use", "id": "t1", "name": "import_media",
            "input": ["source": ["bytes": String(repeating: "A", count: 2_000_000)]],
        ]])]
        let (out, truncated) = ContextBudget.truncateAllOversizedText(from: msgs)
        #expect(truncated == 1)
        let inputBytes = (try? JSONSerialization.data(
            withJSONObject: out[0].content[0]["input"] ?? [:]).count) ?? .max
        #expect(inputBytes < 1_000)
    }

    @Test func serializedBodyStaysUnderByteCapWithGiantTextToolResults() throws {
        // Byte-gate escape hatch 2: text weight alone must not dead-end.
        var msgs: [AnthropicMessage] = []
        for i in 0..<10 {
            msgs.append(AnthropicMessage(role: .assistant, content: [[
                "type": "tool_use", "id": "t\(i)", "name": "inspect_media", "input": ["mediaRef": "m\(i)"],
            ]]))
            msgs.append(toolResultTextMessage(chars: 2_000_000, toolUseId: "t\(i)"))
        }
        let body = try VeniceAgentClient.serializedBody(
            model: "test-model", maxTokens: 8192, system: "sys", tools: [],
            messages: msgs, characterSlug: nil
        )
        #expect(body.count <= VeniceAgentClient.maxRequestBodyBytes)
    }

    @Test func payloadCeilingConstantIsSane() {
        // ~3MB of content at 4 chars/token = 750k tokens; must be positive and
        // meaningfully below typical big-context models' windows won't matter —
        // the min() in AgentService picks the smaller ceiling.
        #expect(ContextBudget.maxPayloadBytes > 1_000_000)
        #expect(ContextBudget.maxPayloadBytes / ContextBudget.charsPerToken > 100_000)
    }
}
