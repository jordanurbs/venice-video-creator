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

    @Test func negativePromptSuppressesAudioPerContent() {
        var shot = Shot(id: "s1", summary: "x", prompt: "x")
        shot.audioContent = .full
        #expect(ShotPromptBuilder.negativePrompt(for: shot) == nil)
        shot.audioContent = .noMusic
        #expect(ShotPromptBuilder.negativePrompt(for: shot)?.contains("background music") == true)
        shot.audioContent = .dialogueOnly
        #expect(ShotPromptBuilder.negativePrompt(for: shot)?.contains("soundtrack") == true)
        shot.audioContent = .ambienceOnly
        let ambient = ShotPromptBuilder.negativePrompt(for: shot)
        #expect(ambient?.contains("speech") == true)
        #expect(ambient?.contains("background music") == true)
    }

    @Test func windowNegativeUsesStrongestSuppression() {
        var full = Shot(id: "a", summary: "x", prompt: "x"); full.audioContent = .full
        var noMusic = Shot(id: "b", summary: "x", prompt: "x"); noMusic.audioContent = .noMusic
        var ambience = Shot(id: "c", summary: "x", prompt: "x"); ambience.audioContent = .ambienceOnly
        #expect(ShotPromptBuilder.negativePrompt(forWindow: [full]) == nil)
        #expect(ShotPromptBuilder.negativePrompt(forWindow: [full, noMusic])?.contains("background music") == true)
        // ambience (speech suppression) wins over plain no-music.
        #expect(ShotPromptBuilder.negativePrompt(forWindow: [noMusic, ambience])?.contains("speech") == true)
    }

    @Test func negativePromptCapabilityIsConservative() {
        #expect(VideoModelCapabilities.supportsNegativePrompt(id: "seedance-2-0-fast-reference-to-video"))
        #expect(VideoModelCapabilities.supportsNegativePrompt(id: "kling-2.6-pro-image-to-video"))
        #expect(!VideoModelCapabilities.supportsNegativePrompt(id: "some-unknown-model-xyz"))
    }

    @Test func negativePromptRoundTripsThroughGenerationInput() throws {
        var input = GenerationInput(prompt: "p", model: "m", duration: 5, aspectRatio: "16:9", resolution: nil)
        input.negativePrompt = "background music, soundtrack"
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(GenerationInput.self, from: data)
        #expect(decoded.negativePrompt == "background music, soundtrack")
    }

    @Test func panelPromptInjectsLocationLightingAndBlocking() {
        var location = LocationSpec(
            id: "loc1", name: "Dive bar",
            description: "a smoky 1970s dive bar with red vinyl booths",
            spatialAnchors: "bar counter along the left wall; entrance door on the right"
        )
        location.lightingNotes = "low tungsten glow, warm key from the bar, deep shadows"
        let shot = Shot(
            id: "s1", summary: "Mara waits", prompt: "Mara nurses a drink at the counter",
            locationIds: ["loc1"],
            blocking: "Mara at the counter, screen left, facing right"
        )
        let plan = ShotPlan(shots: [shot], characters: [], locations: [location])
        let panel = ShotPromptBuilder.storyboardPanelPrompt(for: shot, plan: plan)
        #expect(panel.contains("cinematic storyboard frame"))
        #expect(panel.contains("Location: a smoky 1970s dive bar"))
        #expect(panel.contains("Lighting: low tungsten glow"))
        #expect(panel.contains("Blocking: Mara at the counter, screen left"))
        #expect(panel.contains("Fixed layout (never rearrange): bar counter along the left wall"))
        // No motion/audio steering in a still panel.
        #expect(!panel.contains("static camera"))
    }

    @Test func panelPromptMatchPreviousClauseIsOptIn() {
        let shot = Shot(id: "s2", summary: "A wave", prompt: "A crashing wave")
        let plan = ShotPlan(shots: [shot], characters: [], locations: [])
        #expect(!ShotPromptBuilder.storyboardPanelPrompt(for: shot, plan: plan).contains("Match the lighting"))
        #expect(ShotPromptBuilder.storyboardPanelPrompt(for: shot, plan: plan, matchPreviousPanel: true)
            .contains("Match the lighting, colour, and layout of the previous panel"))
    }

    @Test func lightingNotesRoundTripThroughCodable() throws {
        var location = LocationSpec(id: "loc1", name: "Bar")
        location.lightingNotes = "golden hour, warm key screen-left"
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(LocationSpec.self, from: data)
        #expect(decoded.lightingNotes == "golden hour, warm key screen-left")
    }

    @Test func blockingRoundTripsThroughCodable() throws {
        let (plan, _) = makePlan()
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(ShotPlan.self, from: data)
        #expect(decoded.shots.first?.blocking?.contains("screen left") == true)
        #expect(decoded.locations.first?.spatialAnchors?.contains("pool table center-back") == true)
    }
}

/// Locked series style block (harness rule 11 / anti-pattern 2, Phase 1.3):
/// the plan's `styleBlock` is front-loaded into every generation prompt.
@Suite("ShotPromptBuilder locked style block")
struct ShotPromptBuilderStyleBlockTests {
    private let style = "grainy 16mm docudrama, desaturated teal-and-amber, hard low-key key light"

    @Test func videoPromptFrontLoadsStyle() {
        var plan = ShotPlan(shots: [], characters: [], locations: [])
        plan.styleBlock = style
        let shot = Shot(id: "s1", summary: "x", prompt: "a car speeds down the coast road")
        plan.shots = [shot]
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(prompt.hasPrefix(style), "style must be the FIRST part of the prompt")
        #expect(prompt.contains("a car speeds down the coast road"))
    }

    @Test func panelPromptFrontLoadsStyleAndAddsReminder() {
        var plan = ShotPlan(shots: [], characters: [], locations: [])
        plan.styleBlock = style
        let shot = Shot(id: "s1", summary: "x", prompt: "a car on the coast road")
        plan.shots = [shot]
        let panel = ShotPromptBuilder.storyboardPanelPrompt(for: shot, plan: plan)
        #expect(panel.hasPrefix(style), "style must lead the panel prompt")
        #expect(panel.contains("Style reminder:"), "panel must carry the style-reminder suffix")
    }

    @Test func multiShotPromptFrontLoadsStyle() {
        var plan = ShotPlan(shots: [], characters: [CharacterSpec(id: "c1", name: "Mara")], locations: [LocationSpec(id: "l1", name: "Bar")])
        plan.styleBlock = style
        let s1 = Shot(id: "s1", summary: "x", prompt: "Mara enters", characterIds: ["c1"], locationIds: ["l1"])
        let s2 = Shot(id: "s2", summary: "x", prompt: "Mara sits", characterIds: ["c1"], locationIds: ["l1"])
        plan.shots = [s1, s2]
        let prompt = MultiShotPlanner.multiShotPrompt(window: [s1, s2], plan: plan)
        #expect(prompt.hasPrefix(style), "style must lead the multi-shot prompt")
    }

    @Test func noStyleBlockLeavesPromptUnprefixed() {
        let plan = ShotPlan(shots: [], characters: [], locations: [])
        let shot = Shot(id: "s1", summary: "x", prompt: "a car on the coast road")
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(prompt.hasPrefix("a car on the coast road"))
        #expect(!prompt.contains("Style reminder:"))
    }

    @Test func styleBlockRoundTripsThroughCodable() throws {
        var plan = ShotPlan(title: "T")
        plan.styleBlock = style
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(ShotPlan.self, from: data)
        #expect(decoded.styleBlock == style)
    }
}

/// Invariant-trait restatement (harness rule 37, Phase 2.4): a character's
/// fixed traits are repeated in every shot prompt so wardrobe/scale/markings
/// don't drift across separately-rendered shots.
@Suite("ShotPromptBuilder trait restatement")
struct ShotPromptBuilderTraitTests {

    @Test func characterTraitsAreRestatedInVideoPrompt() {
        let c = CharacterSpec(id: "c1", name: "Mara", description: "tall woman, buzzcut, oil-stained mechanic's coveralls, brass wrist cuff")
        let shot = Shot(id: "s1", summary: "x", prompt: "Mara crosses the yard", characterIds: ["c1"])
        let plan = ShotPlan(shots: [shot], characters: [c])
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(prompt.contains("Mara: tall woman, buzzcut, oil-stained mechanic's coveralls, brass wrist cuff"))
    }

    @Test func noTraitLineWithoutDescription() {
        let c = CharacterSpec(id: "c1", name: "Mara")
        let shot = Shot(id: "s1", summary: "x", prompt: "Mara crosses the yard", characterIds: ["c1"])
        let plan = ShotPlan(shots: [shot], characters: [c])
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(!prompt.contains("Mara:"))
    }

    @Test func longDescriptionIsTruncated() {
        let long = String(repeating: "weathered ", count: 60)  // > 160 chars
        let c = CharacterSpec(id: "c1", name: "Mara", description: long)
        let shot = Shot(id: "s1", summary: "x", prompt: "Mara waits", characterIds: ["c1"])
        let plan = ShotPlan(shots: [shot], characters: [c])
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: plan)
        #expect(prompt.contains("…"), "an over-long trait line must be truncated with an ellipsis")
    }
}

/// Image reproducibility seed plumbing (Phase 2.2): the plan seed rides
/// GenerationInput → ImageGenerationParams, but emission stays gated off until a
/// family is probe-verified (non-regression).
@Suite("Image seed plumbing")
struct ImageSeedPlumbingTests {

    @Test func imageSeedStaysOffUntilProbed() {
        for id in ["nano-banana-2", "nano-banana-pro", "seedream-v5-lite", "flux-2-pro"] {
            #expect(!ToolExecutor.imageModelSupportsSeed(id))
        }
    }

    @Test func applyReferenceSeedIsNoOpWhenModelNotSeedCapable() {
        var plan = ShotPlan(title: "T"); plan.seed = 777
        var input = GenerationInput(prompt: "p", model: "nano-banana-2", duration: 0, aspectRatio: "1:1", resolution: nil)
        // A model not on the seed allowlist must NOT receive a seed.
        // (Resolve the real model config when present; else assert the gate.)
        #expect(!ToolExecutor.imageModelSupportsSeed("nano-banana-2"))
        input.seed = ToolExecutor.imageModelSupportsSeed("nano-banana-2") ? plan.seed : nil
        #expect(input.seed == nil)
    }

    @Test func imageGenerationParamsEncodesSeedWhenPresent() throws {
        let params = ImageGenerationParams(
            prompt: "p", aspectRatio: "1:1", resolution: nil, quality: nil,
            imageURLs: [], numImages: 1, stylePreset: nil, seed: 4242
        )
        let data = try JSONEncoder().encode(params)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"seed\":4242"))
    }

    @Test func imageGenerationParamsOmitsSeedWhenNil() throws {
        let params = ImageGenerationParams(
            prompt: "p", aspectRatio: "1:1", resolution: nil, quality: nil,
            imageURLs: [], numImages: 1, stylePreset: nil, seed: nil
        )
        let data = try JSONEncoder().encode(params)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"seed\""))
    }
}
