import Foundation
import Testing
@testable import VeniceVideoCreator

/// remove_character / remove_location and the removeReferenceMediaRefs detach
/// path on update_character / update_location — the agent-side counterparts of
/// the panels' delete/replace affordances.
@MainActor
@Suite("production entity remove/detach tools")
struct ProductionEntityToolTests {

    private func seededHarness() -> (ToolHarness, CharacterSpec, LocationSpec) {
        let h = ToolHarness()
        let refA = h.addAsset(type: .image)
        let refB = h.addAsset(type: .image)
        var character = CharacterSpec(name: "Dale")
        character.referenceImageAssetIds = [refA.id, refB.id]
        character.lockedReferenceAssetId = refA.id
        h.editor.upsertCharacter(character)
        var location = LocationSpec(name: "Desert Canyon")
        location.referenceImageAssetIds = [refA.id, refB.id]
        location.lockedReferenceAssetId = refA.id
        h.editor.upsertLocation(location)
        // A shot referencing both, to verify detach-on-remove.
        let shot = Shot(
            summary: "Test shot",
            prompt: "test",
            characterIds: [character.id],
            locationIds: [location.id]
        )
        h.editor.upsertShot(shot)
        return (h, character, location)
    }

    @Test func removeLocationDeletesEntityAndDetachesShots() async throws {
        let (h, _, location) = seededHarness()
        let out = try await h.runOK("remove_location", args: ["locationId": location.id]) as? [String: Any]
        #expect(out?["name"] as? String == "Desert Canyon")
        #expect(h.editor.location(id: location.id) == nil)
        #expect(h.editor.shotPlan?.shots.allSatisfy { !$0.locationIds.contains(location.id) } == true)
        // Reference plates stay in the media library.
        #expect(h.editor.mediaAssets.count == 2)
    }

    @Test func removeCharacterDeletesEntityAndDetachesShots() async throws {
        let (h, character, _) = seededHarness()
        let out = try await h.runOK("remove_character", args: ["characterId": character.id]) as? [String: Any]
        #expect(out?["name"] as? String == "Dale")
        #expect(h.editor.character(id: character.id) == nil)
        #expect(h.editor.shotPlan?.shots.allSatisfy { !$0.characterIds.contains(character.id) } == true)
    }

    @Test func removeLocationUnknownIdErrors() async {
        let (h, _, _) = seededHarness()
        let result = await h.runRaw("remove_location", args: ["locationId": "nope"])
        #expect(result.isError == true)
    }

    @Test func updateCharacterDetachesReference() async throws {
        let (h, character, _) = seededHarness()
        let lockedId = character.lockedReferenceAssetId!
        _ = try await h.runOK("update_character", args: [
            "characterId": character.id,
            "removeReferenceMediaRefs": [lockedId],
        ])
        let updated = h.editor.character(id: character.id)
        #expect(updated?.referenceImageAssetIds.contains(lockedId) == false)
        #expect(updated?.referenceImageAssetIds.count == 1)
        // Detaching the locked ref clears the lock rather than pointing at a ghost.
        #expect(updated?.lockedReferenceAssetId != lockedId)
        // The asset itself is NOT deleted.
        #expect(h.editor.mediaAssets.contains { $0.id == lockedId })
    }

    @Test func updateLocationDetachesReference() async throws {
        let (h, _, location) = seededHarness()
        let removeId = location.referenceImageAssetIds[1]
        _ = try await h.runOK("update_location", args: [
            "locationId": location.id,
            "removeReferenceMediaRefs": [removeId],
        ])
        let updated = h.editor.location(id: location.id)
        #expect(updated?.referenceImageAssetIds == [location.referenceImageAssetIds[0]])
        #expect(h.editor.mediaAssets.contains { $0.id == removeId })
    }

    @Test func deleteMediaDetachesFromEntities() async throws {
        // The root cause of "assets randomly unlinked": deleting a reference
        // image left the character/location pointing at a ghost id.
        let (h, character, location) = seededHarness()
        let doomed = character.referenceImageAssetIds[0] // also location's + locked on both
        let result = await h.runRaw("delete_media", args: ["assetIds": [doomed]])
        #expect(result.isError == false)
        #expect(ToolHarness.textOf(result).contains("Detached from"))

        let c = h.editor.character(id: character.id)
        #expect(c?.referenceImageAssetIds.contains(doomed) == false)
        // Lock repoints to a surviving ref instead of a ghost.
        #expect(c?.lockedReferenceAssetId == character.referenceImageAssetIds[1])
        let l = h.editor.location(id: location.id)
        #expect(l?.referenceImageAssetIds.contains(doomed) == false)
        #expect(l?.lockedReferenceAssetId == location.referenceImageAssetIds[1])
    }

    @Test func deleteMediaDetachesShotStoryboard() async throws {
        let (h, _, _) = seededHarness()
        let panel = h.addAsset(type: .image)
        var shot = h.editor.shotPlan!.shots[0]
        shot.storyboardAssetId = panel.id
        shot.status = .storyboarded
        h.editor.upsertShot(shot)

        _ = await h.runRaw("delete_media", args: ["assetIds": [panel.id]])
        let updated = h.editor.shotPlan!.shots[0]
        #expect(updated.storyboardAssetId == nil)
        // Status falls back so production doesn't think a panel exists.
        #expect(updated.status == .planned)
    }

    @Test func deleteMediaWithoutPlanReferencesLeavesPlanAlone() async throws {
        let (h, character, _) = seededHarness()
        let unrelated = h.addAsset(type: .image)
        let result = await h.runRaw("delete_media", args: ["assetIds": [unrelated.id]])
        #expect(result.isError == false)
        #expect(!ToolHarness.textOf(result).contains("Detached from"))
        #expect(h.editor.character(id: character.id)?.referenceImageAssetIds.count == 2)
    }

    @Test func reconcileHealsPreexistingGhostIds() async throws {
        // Plans saved before deletion detached references carry ghost ids;
        // the restore-time reconcile must scrub them (but never ids that are
        // still in the manifest, e.g. missing-file assets awaiting relink).
        let (h, character, location) = seededHarness()
        var c = h.editor.character(id: character.id)!
        c.referenceImageAssetIds.append("GHOST-1")
        c.lockedReferenceAssetId = "GHOST-1"
        h.editor.upsertCharacter(c)
        var l = h.editor.location(id: location.id)!
        l.referenceImageAssetIds.append("GHOST-2")
        h.editor.upsertLocation(l)

        h.editor.reconcileShotPlanWithMediaLibrary()

        let healedC = h.editor.character(id: character.id)!
        #expect(!healedC.referenceImageAssetIds.contains("GHOST-1"))
        #expect(healedC.lockedReferenceAssetId != "GHOST-1")
        #expect(healedC.referenceImageAssetIds.count == 2)
        let healedL = h.editor.location(id: location.id)!
        #expect(healedL.referenceImageAssetIds == Array(location.referenceImageAssetIds))
    }

    @Test func resetShotsWipesProducedStateKeepsPrompts() async throws {
        let h = ToolHarness()
        let video = h.addAsset(type: .video)
        let panel = h.addAsset(type: .image)
        var shot = Shot(summary: "s", prompt: "tracking shot, car drives through canyon, dust billows")
        shot.videoAssetId = video.id
        shot.storyboardAssetId = panel.id
        shot.status = .placed
        shot.takes = [ShotTake(videoAssetId: video.id, model: "m", recipe: nil, seed: nil)]
        shot.qaSummary = "old QA"
        h.editor.upsertShot(shot)

        let out = try await h.runOK("reset_shots") as? [String: Any]
        #expect(out?["reset"] as? Int == 1)

        let reset = h.editor.shotPlan!.shots[0]
        #expect(reset.status == .planned)
        #expect(reset.videoAssetId == nil)
        #expect(reset.storyboardAssetId == nil)
        #expect(reset.takes.isEmpty)
        #expect(reset.qaSummary == nil)
        // Planning fields untouched; generated media kept.
        #expect(reset.prompt == shot.prompt)
        #expect(h.editor.mediaAssets.count == 2)
    }

    @Test func resetShotsBySpecificId() async throws {
        let h = ToolHarness()
        var a = Shot(summary: "a", prompt: "p")
        a.status = .placed
        var b = Shot(summary: "b", prompt: "p")
        b.status = .placed
        h.editor.upsertShot(a)
        h.editor.upsertShot(b)

        _ = try await h.runOK("reset_shots", args: ["shotIds": [a.id]])
        #expect(h.editor.shotPlan!.shot(id: a.id)?.status == .planned)
        #expect(h.editor.shotPlan!.shot(id: b.id)?.status == .placed)
    }

    @Test func bakeoffChooseModelRefusedWithoutUserConfirmation() async {
        let h = ToolHarness()
        // No userConfirmed/userChoiceQuote: refused regardless of model validity.
        let result = await h.runRaw("reference_bakeoff", args: ["chooseModel": "any-model"])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("USER's decision"))
        // Half-attested (flag without quote) is also refused.
        let half = await h.runRaw("reference_bakeoff", args: [
            "chooseModel": "any-model", "userConfirmed": true,
        ])
        #expect(half.isError == true)
    }

    @Test func entityIdPrefixRoundTrips() async throws {
        // Entity ids are now part of the short-id universe: an 8-char prefix
        // the agent was shown must resolve on the way back in.
        let (h, _, location) = seededHarness()
        let prefix = String(location.id.prefix(8))
        _ = try await h.runOK("update_location", args: [
            "locationId": prefix,
            "name": "Renamed Canyon",
        ])
        #expect(h.editor.location(id: location.id)?.name == "Renamed Canyon")
    }
}
