import Foundation
import Testing
@testable import VeniceVideoCreator

/// Spatial-consistency prompt rules (harness rule 49, ported 2026-08-06):
/// authored blocking and location spatialAnchors are restated verbatim in
/// every generation so geometry is never re-inferred per take.
@Suite("ShotPromptBuilder spatial consistency")
struct ShotPromptBuilderSpatialTests {

    private func makePlan() -> (ShotPlan, Shot) {
        let location = LocationSpec(
            id: "loc1",
            name: "Dive bar",
            spatialAnchors: "bar counter along the left wall; entrance door on the right; pool table center-back"
        )
        let character = CharacterSpec(id: "char1", name: "Mara")
        let shot = Shot(
            id: "s1",
            summary: "Mara waits at the counter",
            prompt: "Mara nurses a drink at the counter as the door opens",
            characterIds: ["char1"],
            locationIds: ["loc1"],
            blocking: "Mara at the bar counter, screen left, facing right toward the door; the door opens in the background, screen right"
        )
        let plan = ShotPlan(shots: [shot], characters: [character], locations: [location])
        return (plan, shot)
    }

    @Test func blockingIsInjectedVerbatim() {
        let (plan, shot) = makePlan()
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(prompt.contains("Blocking: Mara at the bar counter, screen left"))
    }

    @Test func spatialAnchorsInjectFixedLayoutClause() {
        let (plan, shot) = makePlan()
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(prompt.contains("Fixed layout (never rearrange): bar counter along the left wall"))
    }

    @Test func noMirroringClauseWhenCharactersPresent() {
        let (plan, shot) = makePlan()
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(prompt.contains("do not mirror, swap, or rearrange"))
    }

    @Test func facelessShotAtAnchoredLocationSkipsMirrorClause() {
        var (plan, shot) = makePlan()
        shot.characterIds = []
        shot.blocking = nil
        plan.shots = [shot]
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        // Layout still locked, but no character-side clause without subjects.
        #expect(prompt.contains("Fixed layout (never rearrange):"))
        #expect(!prompt.contains("do not mirror, swap, or rearrange"))
    }

    @Test func noSpatialClausesWithoutAuthoredData() {
        let shot = Shot(id: "s2", summary: "A wave crashes", prompt: "Slow dolly toward a crashing wave")
        let plan = ShotPlan(shots: [shot])
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(!prompt.contains("Blocking:"))
        #expect(!prompt.contains("Fixed layout"))
    }

    @Test func nilPlanStillBuildsPromptWithShotBlocking() {
        let (_, shot) = makePlan()
        let prompt = ShotPromptBuilder.videoPrompt(for: shot)
        #expect(prompt.contains("Blocking: Mara at the bar counter"))
        #expect(!prompt.contains("Fixed layout"))
    }

    @Test func voRuleStillHolds() {
        var (plan, shot) = makePlan()
        shot.dialogue = [ShotDialogue(speaker: "NARRATOR", text: "It was a quiet night.", voiceOver: true)]
        plan.shots = [shot]
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(!prompt.contains("It was a quiet night."))
        #expect(prompt.contains("No narration, no voice-over"))
    }

    @Test func blockingRoundTripsThroughCodable() throws {
        let (plan, _) = makePlan()
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(ShotPlan.self, from: data)
        #expect(decoded.shots.first?.blocking?.contains("screen left") == true)
        #expect(decoded.locations.first?.spatialAnchors?.contains("pool table center-back") == true)
    }
}
