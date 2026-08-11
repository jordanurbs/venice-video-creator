import Foundation
import Testing
@testable import VeniceVideoCreator

/// @ImageN slot binding (harness rule 42): the prompt's @ImageN indices and the
/// reference_image_urls push order come from ONE ordered slot list.
@MainActor
@Suite("ReferenceSlots @ImageN binding")
struct ReferenceSlotsTests {

    private func img(_ name: String) -> MediaAsset {
        MediaAsset(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(name).png"), type: .image, name: name)
    }

    private func candidate(_ kind: ReferenceSlots.Kind, _ label: String, _ role: String = "") -> ReferenceSlots.Candidate {
        .init(kind: kind, asset: img(label), label: label, roleClause: role)
    }

    @Test func fillOrderPutsCharactersFirstAndIndexesFromOne() {
        let plan = ReferenceSlots.build(
            primaries: [candidate(.characterPrimary, "Bob"), candidate(.characterPrimary, "Mara")],
            storyboard: [candidate(.storyboard, "panel", ReferenceSlots.storyboardRoleClause)],
            location: [candidate(.location, "Bar", ReferenceSlots.locationRoleClause(name: "Bar", angleIndex: 0))],
            characterAngles: [candidate(.characterAngle, "Bob", ReferenceSlots.characterAngleRoleClause(name: "Bob"))],
            budget: 9
        )
        #expect(plan.slots.map(\.imageIndex) == [1, 2, 3, 4, 5])
        #expect(plan.slots[0].kind == .characterPrimary)
        #expect(plan.characterSlotByName["BOB"] == 1)
        #expect(plan.characterSlotByName["MARA"] == 2)
    }

    @Test func overflowDropsFromBottomTierFirst() {
        // Budget 3: two primaries + panel fill it; location + angles drop.
        let plan = ReferenceSlots.build(
            primaries: [candidate(.characterPrimary, "Bob"), candidate(.characterPrimary, "Mara")],
            storyboard: [candidate(.storyboard, "panel")],
            location: [candidate(.location, "Bar")],
            characterAngles: [candidate(.characterAngle, "Bob")],
            budget: 3
        )
        #expect(plan.slots.count == 3)
        #expect(plan.slots.last?.kind == .storyboard)
        #expect(plan.characterSlotByName.count == 2)
    }

    @Test func perBeatPlatesAllKeptAndAnnounced() {
        // Three beat plates + one primary, budget 9: every plate survives and each
        // emits its own @ImageN role line (harness rule 42 per-beat plates).
        let plates = ["beat-1", "beat-2", "beat-3"].map {
            candidate(.storyboard, $0, ReferenceSlots.storyboardBeatRoleClause(slug: $0))
        }
        let plan = ReferenceSlots.build(
            primaries: [candidate(.characterPrimary, "Bob")],
            storyboard: plates,
            location: [candidate(.location, "Bar")],
            characterAngles: [],
            budget: 9
        )
        #expect(plan.slots.filter { $0.kind == .storyboard }.count == 3)
        let plateLines = plan.roleClauseLines.filter { $0.contains("storyboard blocking plate") }
        #expect(plateLines.count == 3)
        #expect(plateLines.contains { $0.contains("beat-2") })
    }

    @Test func platesSurviveOverflowBeforeLocationAndAngles() {
        // Budget 3: primary + 2 plates fill it; location + angle drop (plates last
        // to go). Plates sit right after the primary.
        let plates = ["beat-1", "beat-2"].map { candidate(.storyboard, $0) }
        let plan = ReferenceSlots.build(
            primaries: [candidate(.characterPrimary, "Bob")],
            storyboard: plates,
            location: [candidate(.location, "Bar")],
            characterAngles: [candidate(.characterAngle, "Bob")],
            budget: 3
        )
        #expect(plan.slots.count == 3)
        #expect(plan.slots.filter { $0.kind == .storyboard }.count == 2)
        #expect(!plan.slots.contains { $0.kind == .location })
    }

    @Test func identityAndRoleLinesFormat() {
        let plan = ReferenceSlots.build(
            primaries: [candidate(.characterPrimary, "Bob")],
            storyboard: [],
            location: [candidate(.location, "Bar", ReferenceSlots.locationRoleClause(name: "Bar", angleIndex: 0))],
            characterAngles: [],
            budget: 9
        )
        #expect(plan.identityDeclarations.first == "@Image1 is Bob — use this reference for Bob's face, hair, and wardrobe.")
        #expect(plan.roleClauseLines.first?.hasPrefix("@Image2 is the location environment reference (Bar)") == true)
    }

    @Test func substitutesWholeWordCaseInsensitiveLongestFirst() {
        let plan = ReferenceSlots.build(
            primaries: [candidate(.characterPrimary, "Bo"), candidate(.characterPrimary, "Bobby")],
            storyboard: [], location: [], characterAngles: [], budget: 9
        )
        // "Bobby" (index 2) must win over "Bo" (index 1) inside the same word.
        let out = plan.substitutingNames(in: "bobby greets Bo at the door")
        #expect(out == "@Image2 greets @Image1 at the door")
    }

    @Test func shotPromptGainsBindingsWhenSlotPlanPresent() {
        let plan = ReferenceSlots.build(
            primaries: [candidate(.characterPrimary, "Bob")],
            storyboard: [], location: [], characterAngles: [], budget: 9
        )
        let shot = Shot(id: "s1", summary: "", prompt: "Bob waves at the camera")
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: nil, slotPlan: plan)
        #expect(prompt.contains("@Image1 is Bob"))
        #expect(prompt.contains("@Image1 waves at the camera"))
        #expect(!prompt.contains("Bob waves"))
    }

    @Test func noSlotPlanKeepsNamePath() {
        let shot = Shot(id: "s1", summary: "", prompt: "Bob waves at the camera")
        let prompt = ShotPromptBuilder.videoPrompt(for: shot, plan: nil, slotPlan: nil)
        #expect(prompt.contains("Bob waves at the camera"))
        #expect(!prompt.contains("@Image"))
    }
}
