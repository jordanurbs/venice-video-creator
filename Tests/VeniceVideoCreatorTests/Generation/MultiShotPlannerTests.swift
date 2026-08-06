import Foundation
import Testing
@testable import VeniceVideoCreator

/// Multi-shot grouping (harness rule 21, ported 2026-08-06): consecutive
/// same-location shots with overlapping characters group into one generation.
@Suite("MultiShotPlanner grouping")
struct MultiShotPlannerTests {

    private func makePlan(shotCount: Int = 3, seconds: Double = 4) -> ShotPlan {
        let char = CharacterSpec(id: "c1", name: "Mara")
        let loc = LocationSpec(id: "l1", name: "Bar")
        let shots = (0..<shotCount).map { i in
            Shot(
                id: "s\(i + 1)", slug: "S\(i + 1)",
                summary: "Beat \(i + 1)", prompt: "Mara does thing \(i + 1)",
                durationSeconds: seconds,
                transition: .cut,
                characterIds: ["c1"], locationIds: ["l1"]
            )
        }
        return ShotPlan(shots: shots, characters: [char], locations: [loc])
    }

    @Test func groupsSameSceneWindow() {
        let plan = makePlan(shotCount: 3, seconds: 4) // 12s total
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units.count == 1)
        #expect(units[0].isMultiShot)
        #expect(units[0].shotIds == ["s1", "s2", "s3"])
    }

    @Test func disabledGroupingYieldsSingles() {
        let plan = makePlan(shotCount: 3)
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: false)
        #expect(units.count == 3)
        #expect(units.allSatisfy { !$0.isMultiShot })
    }

    @Test func fifteenSecondCapSplitsWindow() {
        // 3 × 6s = 18s > 15s → only the first two group (12s), third is single.
        let plan = makePlan(shotCount: 3, seconds: 6)
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units.count == 2)
        #expect(units[0].shotIds == ["s1", "s2"])
        #expect(!units[1].isMultiShot)
    }

    @Test func locationChangeBreaksWindow() {
        var plan = makePlan(shotCount: 3, seconds: 4)
        plan.locations.append(LocationSpec(id: "l2", name: "Street"))
        plan.shots[2].locationIds = ["l2"]
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units.count == 2)
        #expect(units[0].shotIds == ["s1", "s2"])
    }

    @Test func noCharacterOverlapBreaksWindow() {
        var plan = makePlan(shotCount: 2, seconds: 4)
        plan.characters.append(CharacterSpec(id: "c2", name: "Jax"))
        plan.shots[1].characterIds = ["c2"]
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units.allSatisfy { !$0.isMultiShot })
    }

    @Test func emptyCharactersOrLocationNeverGroups() {
        var plan = makePlan(shotCount: 2, seconds: 4)
        plan.shots[0].characterIds = []
        #expect(MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
            .allSatisfy { !$0.isMultiShot })
        var plan2 = makePlan(shotCount: 2, seconds: 4)
        plan2.shots[0].locationIds = []
        plan2.shots[1].locationIds = []
        #expect(MultiShotPlanner.plan(shots: plan2.shots, plan: plan2, groupingEnabled: true)
            .allSatisfy { !$0.isMultiShot })
    }

    @Test func allowMultiShotFalseOptsOut() {
        var plan = makePlan(shotCount: 3, seconds: 4)
        plan.shots[1].allowMultiShot = false
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units.allSatisfy { !$0.isMultiShot })
    }

    @Test func modelOverrideOptsOut() {
        var plan = makePlan(shotCount: 2, seconds: 4)
        plan.shots[0].modelOverride = "kling-2.6-pro-image-to-video"
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units.allSatisfy { !$0.isMultiShot })
    }

    @Test func voiceOverShotStaysSingle() {
        var plan = makePlan(shotCount: 2, seconds: 4)
        plan.shots[0].dialogue = [ShotDialogue(speaker: "NARRATOR", text: "Meanwhile.", voiceOver: true)]
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units.allSatisfy { !$0.isMultiShot })
    }

    @Test func fadeTransitionBreaksWindow() {
        var plan = makePlan(shotCount: 3, seconds: 4)
        plan.shots[0].transition = .fadeToBlack
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        // s1's transition leads INTO s2, so s1 can't group forward; s2+s3 can.
        #expect(units.count == 2)
        #expect(!units[0].isMultiShot)
        #expect(units[1].shotIds == ["s2", "s3"])
    }

    @Test func maxSixShotsPerWindow() {
        let plan = makePlan(shotCount: 8, seconds: 1)
        let units = MultiShotPlanner.plan(shots: plan.shots, plan: plan, groupingEnabled: true)
        #expect(units[0].shotIds.count == 6)
        #expect(units[1].shotIds.count == 2)
    }
}

@Suite("MultiShotPlanner prompt")
struct MultiShotPromptTests {

    private func makePlan() -> ShotPlan {
        let mara = CharacterSpec(id: "c1", name: "Mara")
        let jax = CharacterSpec(id: "c2", name: "Jax")
        var loc = LocationSpec(id: "l1", name: "Bar", description: "A dim dive bar")
        loc.spatialAnchors = "counter left; door right"
        let s1 = Shot(
            id: "s1", summary: "", prompt: "Mara leans on the counter",
            durationSeconds: 5, characterIds: ["c1", "c2"], locationIds: ["l1"],
            dialogue: [ShotDialogue(characterId: "c1", text: "You're late.")],
            blocking: "Mara screen left at the counter"
        )
        let s2 = Shot(
            id: "s2", summary: "", prompt: "Jax closes the door behind him",
            durationSeconds: 4, characterIds: ["c1", "c2"], locationIds: ["l1"]
        )
        return ShotPlan(shots: [s1, s2], characters: [mara, jax], locations: [loc])
    }

    @Test func promptHasBeatsAndLensSwitch() {
        let plan = makePlan()
        let prompt = MultiShotPlanner.multiShotPrompt(window: plan.shots, plan: plan)
        #expect(prompt.contains("Shot 1 (5s): Mara leans on the counter"))
        #expect(prompt.contains("Lens switch."))
        #expect(prompt.contains("Shot 2 (4s): Jax closes the door"))
        // Exactly one separator for two beats.
        #expect(prompt.components(separatedBy: "Lens switch.").count == 2)
    }

    @Test func promptCarriesIdentityLockAndGeometry() {
        let plan = makePlan()
        let prompt = MultiShotPlanner.multiShotPrompt(window: plan.shots, plan: plan)
        #expect(prompt.contains("Mara appears exactly as in the reference images."))
        #expect(prompt.contains("Jax appears exactly as in the reference images."))
        #expect(prompt.contains("2-shot continuous sequence"))
        #expect(prompt.contains("Fixed layout (never rearrange): counter left; door right"))
        #expect(prompt.contains("do not mirror, swap, or rearrange"))
    }

    @Test func promptCarriesBlockingAndDialogue() {
        let plan = makePlan()
        let prompt = MultiShotPlanner.multiShotPrompt(window: plan.shots, plan: plan)
        #expect(prompt.contains("Blocking: Mara screen left at the counter"))
        #expect(prompt.contains("[Mara]: \"You're late.\""))
    }

    @Test func promptRespectsCharLimit() {
        var plan = makePlan()
        plan.shots[0].prompt = String(repeating: "very long action ", count: 300)
        let prompt = MultiShotPlanner.multiShotPrompt(window: plan.shots, plan: plan)
        #expect(prompt.count <= VideoModelCapabilities.videoPromptCharLimit)
    }
}
