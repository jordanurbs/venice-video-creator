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

    @Test func payloadCeilingConstantIsSane() {
        // ~3MB of content at 4 chars/token = 750k tokens; must be positive and
        // meaningfully below typical big-context models' windows won't matter —
        // the min() in AgentService picks the smaller ceiling.
        #expect(ContextBudget.maxPayloadBytes > 1_000_000)
        #expect(ContextBudget.maxPayloadBytes / ContextBudget.charsPerToken > 100_000)
    }
}
