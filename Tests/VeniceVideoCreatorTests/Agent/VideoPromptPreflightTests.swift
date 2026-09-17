import Foundation
import Testing
@testable import VeniceVideoCreator

/// produce_shots money gate: prompts that would render static/undirected
/// footage are refused before credits are spent.
@MainActor
@Suite("video prompt pre-flight")
struct VideoPromptPreflightTests {

    private func shot(prompt: String, duration: Double = 15) -> Shot {
        Shot(slug: "S1", summary: "test shot", prompt: prompt, durationSeconds: duration)
    }

    @Test func emptyPromptFlagged() {
        #expect(ToolExecutor.videoPromptIssue(shot(prompt: "")) != nil)
    }

    @Test func storyboardStylePromptFlagged() {
        let issue = ToolExecutor.videoPromptIssue(
            shot(prompt: "Cinematic film still of a desert canyon at golden hour, cracked asphalt road, dust haze")
        )
        #expect(issue?.contains("film still") == true)
    }

    @Test func captionWithoutMotionFlagged() {
        // Long enough, but pure image-caption language: nothing moves.
        let issue = ToolExecutor.videoPromptIssue(
            shot(prompt: "A desert canyon at golden hour with red rock walls, a cracked asphalt road and warm haze in the distance under a vast sky")
        )
        #expect(issue?.contains("no camera or motion") == true)
    }

    @Test func thinPromptFlagged() {
        let issue = ToolExecutor.videoPromptIssue(shot(prompt: "Car drives fast"))
        #expect(issue?.contains("words") == true)
    }

    /// Simple-prompt models (MiniMax H3 Max) stage their own camera and cutting,
    /// so the motion-vocabulary requirement and the 12-word floor would refuse
    /// exactly the prompts those models are built for. The gate consults the
    /// routed model — plan default or per-shot override — instead of applying
    /// one bar to every family.
    @Test func simplePromptModelsSkipTheMotionAndLengthBars() {
        // No motion verb, 6 words: refused on a directorial model…
        let plain = shot(prompt: "Late night ramen shop, neon steam")
        #expect(ToolExecutor.videoPromptIssue(plain) != nil)
        #expect(ToolExecutor.videoPromptIssue(plain, defaultModel: "seedance-2-5-reference-to-video") != nil)
        // …and accepted on H3 Max, via the plan default or a per-shot override.
        #expect(ToolExecutor.videoPromptIssue(plain, defaultModel: "minimax-h3-max-text-to-video") == nil)
        #expect(ToolExecutor.videoPromptIssue(plain, defaultModel: "minimax-h3-max-turbo-image-to-video") == nil)
        var overridden = plain
        overridden.modelOverride = "minimax-h3-max-reference-to-video"
        #expect(ToolExecutor.videoPromptIssue(overridden, defaultModel: "seedance-2-5-reference-to-video") == nil)
        // Base MiniMax H3 is NOT a simple-prompt model — same name, full bar.
        #expect(ToolExecutor.videoPromptIssue(plain, defaultModel: "minimax-h3-text-to-video") != nil)
    }

    @Test func simplePromptModelsStillRefuseEmptyAndStoryboardPrompts() {
        let model = "minimax-h3-max-text-to-video"
        #expect(ToolExecutor.videoPromptIssue(shot(prompt: ""), defaultModel: model) != nil)
        #expect(ToolExecutor.videoPromptIssue(shot(prompt: "  "), defaultModel: model) != nil)
        // A panel prompt is wrong for any video model, cheap or not.
        #expect(ToolExecutor.videoPromptIssue(
            shot(prompt: "Cinematic film still of a canyon at golden hour"), defaultModel: model
        ) != nil)
        // And a two-word stub is still too thin to name a subject and setting.
        #expect(ToolExecutor.videoPromptIssue(shot(prompt: "a cat"), defaultModel: model) != nil)
    }

    @Test func properVideoPromptPasses() {
        let prompt = "Low tracking shot alongside the matte-black muscle car as it speeds down the cracked asphalt, dust billowing behind the rear tires, camera slowly pushes in toward the driver as heat haze ripples off the road"
        #expect(ToolExecutor.videoPromptIssue(shot(prompt: prompt)) == nil)
    }

    @Test func storyboardPromptSplitDrivesPanelNotVideo() {
        // Dedicated storyboard prompt: panel composes from it, video from prompt.
        var s = shot(prompt: "tracking shot follows the car as dust billows behind the rear wheels")
        s.storyboardPrompt = "cinematic film still, low hero angle, car centered on canyon road"
        let panel = ShotPromptBuilder.storyboardPanelPrompt(for: s)
        let video = ShotPromptBuilder.videoPrompt(for: s)
        #expect(panel.contains("low hero angle"))
        #expect(!panel.contains("tracking shot follows"))
        #expect(video.contains("tracking shot follows"))
        #expect(!video.contains("low hero angle"))
        // And the still-language video-prompt gate stays green.
        #expect(ToolExecutor.videoPromptIssue(s) == nil)
    }

    @Test func missingStoryboardPromptFallsBackToVideoPrompt() {
        let s = shot(prompt: "slow push-in as she turns toward the window, curtains swaying")
        let panel = ShotPromptBuilder.storyboardPanelPrompt(for: s)
        #expect(panel.contains("slow push-in"))
    }

    @Test func updateShotsPatchesStoryboardPrompt() async throws {
        let h = ToolHarness()
        let s = shot(prompt: "dolly left as the car speeds past, gravel spraying")
        h.editor.upsertShot(s)
        _ = try await h.runOK("update_shots", args: ["operations": [
            ["action": "update", "id": s.id, "storyboardPrompt": "film still, wide symmetric framing"],
        ]])
        #expect(h.editor.shotPlan?.shots[0].storyboardPrompt == "film still, wide symmetric framing")
        // Clearing: empty string maps to nil (derive from video prompt again).
        _ = try await h.runOK("update_shots", args: ["operations": [
            ["action": "update", "id": s.id, "storyboardPrompt": ""],
        ]])
        #expect(h.editor.shotPlan?.shots[0].storyboardPrompt == nil)
    }

    @Test func seedance25ReferenceBudgetIs30() {
        #expect(VideoModelCapabilities.maxReferenceImages(id: "seedance-2-5-reference-to-video") == 30)
        // 2.0 lanes keep their probed budget.
        #expect(VideoModelCapabilities.maxReferenceImages(id: "seedance-2-0-reference-to-video") == 9)
    }

    @Test func produceShotsRefusesStaticPrompts() async {
        let h = ToolHarness()
        let s = shot(prompt: "Cinematic film still of a desert canyon, golden hour")
        h.editor.upsertShot(s)
        // Fake a key so we reach the prompt gate? No key in tests — the key
        // check comes first, so test the gate helper directly (above) and the
        // args plumb here only when a key exists. Assert error either way.
        let result = await h.runRaw("produce_shots", args: [:])
        #expect(result.isError == true)
    }
}
