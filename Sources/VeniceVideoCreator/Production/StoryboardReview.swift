import AppKit
import CryptoKit
import Foundation

struct StoryboardRevision: Codable, Sendable, Equatable {
    let assetID: String
    let contentDigest: String
    let settingsDigest: String
}

struct StoryboardReview: Codable, Sendable, Equatable {
    enum Verdict: String, Codable, Sendable { case passed, failed, unchecked, error }
    let revision: StoryboardRevision
    let verdict: Verdict
    let reviewer: String
    let summary: String
    var approvedBy: String?
    var approvalReason: String?
    var approvedAt: Date?
    let reviewedAt: Date
}

struct StoryboardSubmissionBinding: Codable, Sendable, Equatable {
    let shotID: String
    let revision: StoryboardRevision
}

enum StoryboardReviewGate {
    private struct Settings: Encodable {
        let shot: Shot
        let aspectRatio: String
        let resolution: String
        let styleBlock: String?
        let model: String?
        let characters: [CharacterSpec]
        let locations: [LocationSpec]
        let priorPanelID: String?
    }

    static func settingsDigest(shot: Shot, plan: ShotPlan) throws -> String {
        var settings = shot
        settings.panelReview = nil
        settings.status = .planned
        settings.videoAssetId = nil
        settings.placement = nil
        settings.takes = []
        settings.qaSummary = nil
        settings.failureReason = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let index = plan.shots.firstIndex(where: { $0.id == shot.id }) ?? 0
        let priorPanelID = plan.shots.prefix(index).last {
            !Set($0.locationIds).isDisjoint(with: shot.locationIds) && $0.storyboardAssetId != nil
        }?.storyboardAssetId
        let data = try encoder.encode(Settings(
            shot: settings, aspectRatio: plan.aspectRatio, resolution: plan.resolution,
            styleBlock: plan.styleBlock, model: shot.modelOverride ?? plan.defaultModel,
            characters: shot.characterIds.compactMap { plan.character(id: $0) },
            locations: shot.locationIds.compactMap { plan.location(id: $0) }, priorPanelID: priorPanelID
        ))
        return digest(data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension EditorViewModel {
    func storyboardRevision(for shot: Shot, plan: ShotPlan) throws -> StoryboardRevision {
        guard let id = shot.storyboardAssetId,
              let panel = mediaAssets.first(where: { $0.id == id }), panel.type == .image,
              ToolExecutor.isReady(panel, editor: self),
              let url = mediaResolver.resolveURL(for: id),
              let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
            throw ToolError("Wait for a decodable storyboard panel before reviewing or producing \(shot.slug ?? shot.id).")
        }
        return try StoryboardRevision(assetID: id, contentDigest: StoryboardReviewGate.digest(data), settingsDigest: StoryboardReviewGate.settingsDigest(shot: shot, plan: plan))
    }

    func requireApprovedStoryboard(for shot: Shot, plan: ShotPlan) throws -> StoryboardRevision? {
        guard shot.storyboardAssetId != nil else { return nil }
        let revision = try storyboardRevision(for: shot, plan: plan)
        guard let review = shot.panelReview, review.revision == revision, review.approvedBy != nil else {
            throw ToolError("Approve the current storyboard revision for \(shot.slug ?? shot.id) before producing. Review the panel, then use Approve Storyboard or update_shots with approveStoryboard and approvalReason.")
        }
        guard review.verdict == .passed || review.approvalReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ToolError("Record a reason to override failed or unchecked storyboard QA.")
        }
        return revision
    }

    func approveStoryboard(shotID: String, reason: String, approvedBy: String = "user") throws {
        guard let plan = shotPlan, let shot = plan.shot(id: shotID) else { throw ToolError("Shot not found: \(shotID)") }
        let review = try storyboardApproval(for: shot, plan: plan, reason: reason, approvedBy: approvedBy)
        mutateShotPlan(actionName: "Approve Storyboard") { plan in
            guard let index = plan.shots.firstIndex(where: { $0.id == shotID }) else { return }
            plan.shots[index].panelReview = review
            if plan.shots[index].videoAssetId == nil { plan.shots[index].status = .approved }
        }
    }

    func storyboardApproval(for shot: Shot, plan: ShotPlan, reason: String, approvedBy: String) throws -> StoryboardReview {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw ToolError("Record why this storyboard revision is approved.") }
        let revision = try storyboardRevision(for: shot, plan: plan)
        var review = shot.panelReview.flatMap { $0.revision == revision ? $0 : nil }
            ?? StoryboardReview(revision: revision, verdict: .unchecked, reviewer: approvedBy, summary: "Manual storyboard review", reviewedAt: Date())
        review.approvedBy = approvedBy
        review.approvalReason = reason
        review.approvedAt = Date()
        return review
    }

    func validateStoryboardSubmission(_ binding: StoryboardSubmissionBinding?) throws {
        guard let binding else { return }
        guard let plan = shotPlan, let shot = plan.shot(id: binding.shotID),
              try requireApprovedStoryboard(for: shot, plan: plan) == binding.revision else {
            throw ToolError("The storyboard changed after this request was prepared. Approve the current revision and submit again.")
        }
    }

    func storyboardBindings(for shots: [Shot], plan: ShotPlan) throws -> [StoryboardSubmissionBinding] {
        try shots.compactMap { shot in
            guard let revision = try requireApprovedStoryboard(for: shot, plan: plan) else { return nil }
            return StoryboardSubmissionBinding(shotID: shot.id, revision: revision)
        }
    }

    @discardableResult
    func recordStoryboardReview(shotID: String, review: StoryboardReview) throws -> Bool {
        guard let plan = shotPlan, let shot = plan.shot(id: shotID),
              try storyboardRevision(for: shot, plan: plan) == review.revision else { return false }
        mutateShotPlan(actionName: "Review Storyboard") { plan in
            guard let index = plan.shots.firstIndex(where: { $0.id == shotID }) else { return }
            plan.shots[index].panelReview = review
            plan.shots[index].qaSummary = review.summary
            if plan.shots[index].videoAssetId == nil {
                plan.shots[index].status = review.approvedBy == nil ? .storyboarded : .approved
            }
        }
        return true
    }
}
