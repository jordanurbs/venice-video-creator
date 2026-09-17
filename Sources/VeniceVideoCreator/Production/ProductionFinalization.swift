import CryptoKit
import Foundation
import ImageIO

struct ProductionFinalization: Codable, Sendable, Equatable {
    struct Review: Codable, Sendable, Equatable {
        let shotId: String
        let sourceRange: ShotSourceRange
        let reviewer: String
        let passed: Bool
        let summary: String
        let reviewedAt: Date
        var approvalReason: String?
        var qaPassed: Bool?
    }
    let assetId: String
    let contentDigest: String
    let validatedAt: Date
    var validationFailure: String?
    var reviews: [Review] = []
    var placements: [String: ShotPlacement] = [:]
}

extension ProductionOrchestrator {
    enum FinalizationOutcome: Equatable { case placed, rejected, unchecked, stopped }

    func finalizationFailure(_ operationId: String) -> String {
        guard let operation = editor?.productionOperation(id: operationId) else { return "Production operation is missing." }
        let evidence = operation.attempts.last?.finalization
        return operation.failureReason ?? evidence?.validationFailure
            ?? evidence?.reviews.first(where: { !$0.passed })?.summary ?? "Review the retained take before placement."
    }

    func hasCurrentFinalizedPlacement(_ operation: ProductionOperation) -> Bool {
        guard let editor, let placements = operation.attempts.last?.finalization?.placements,
              placements.count == operation.destinations.count else { return false }
        return placements.allSatisfy { shotId, placement in
            guard editor.shot(id: shotId)?.placement == placement else { return false }
            return ([placement.videoClipId] + placement.linkedAudioClipIds).allSatisfy { editor.clipFor(id: $0)?.mediaRef == placement.assetId }
        }
    }

    func finalizationIsCurrent(_ operationId: String, runId: UUID) -> Bool {
        guard acceptsSubmissions(runId: runId), !Task.isCancelled, let editor else { return false }
        return (try? editor.requireProductionDestination(operationId)) != nil
    }

    func outputDigest(_ asset: MediaAsset) async throws -> String {
        if let digestVideo { return try await digestVideo(asset) }
        guard let url = editor?.mediaResolver.resolveURL(for: asset.id) else { throw ToolError("Generated video cannot be resolved.") }
        return try await Task.detached {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    func expectedOutputAspect(for recipe: GenerationInput) throws -> String {
        guard MiniMaxVideoContract.inheritsAspect(recipe.model) else { return recipe.aspectRatio }
        guard let assetId = recipe.imageURLAssetIds?.first,
              let url = editor?.mediaResolver.resolveURL(for: assetId),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
            throw ToolError("Decode the original first frame before validating inherited video aspect.")
        }
        return "\(image.width):\(image.height)"
    }

    func finalizeAttempt(operationId: String, runId: UUID, approvalReason: String? = nil) async -> FinalizationOutcome {
        guard let editor, let initial = editor.productionOperation(id: operationId),
              let attempt = initial.attempts.last, let assetId = attempt.placeholderId,
              let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else { return .unchecked }
        guard asset.generationStatus == .none else {
            editor.mutateProductionOperation(operationId) { $0.failureReason = "Video is not ready: \(asset.generationStatus.serialized)." }
            return .unchecked
        }
        guard finalizingAttemptIds.insert(attempt.id).inserted else { return .stopped }
        defer { finalizingAttemptIds.remove(attempt.id) }
        if initial.stage == .placed {
            guard hasCurrentFinalizedPlacement(initial) else { return .unchecked }
            do {
                editor.mutateProductionOperation(operationId) { $0.failureReason = nil }
                try await editor.checkpointProductionState()
                return .placed
            } catch {
                editor.mutateProductionOperation(operationId) { $0.failureReason = error.localizedDescription }
                return .unchecked
            }
        }
        guard finalizationIsCurrent(operationId, runId: runId) else { return .stopped }
        let reason = approvalReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let digest = try await outputDigest(asset)
            guard finalizationIsCurrent(operationId, runId: runId) else { return .stopped }
            editor.mutateProductionOperation(operationId) { $0.stage = .validating }
            let expectedAspect = try expectedOutputAspect(for: attempt.recipe)
            let check = await validate(asset: asset, duration: Double(attempt.recipe.duration), aspect: expectedAspect)
            guard finalizationIsCurrent(operationId, runId: runId) else { return .stopped }
            var evidence = attempt.finalization.flatMap { $0.assetId == assetId && $0.contentDigest == digest ? $0 : nil }
                ?? ProductionFinalization(assetId: assetId, contentDigest: digest, validatedAt: Date())
            evidence.validationFailure = check.ok ? nil : check.reason ?? "Output failed validation."
            storeFinalization(evidence, operationId: operationId, attemptId: attempt.id)
            guard check.ok else { return .rejected }
            let planned = initial.destinations.compactMap(\.plannedSeconds)
            guard planned.count == initial.destinations.count, planned.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw ToolError("Operation has no saved beat timing. Bind the retained take manually.")
            }
            let plannedTotal = planned.reduce(0, +)
            guard plannedTotal.isFinite, asset.duration + 1 / Double(max(1, editor.timeline.fps)) >= plannedTotal else {
                evidence.validationFailure = "Generated video does not cover the planned beat durations."
                storeFinalization(evidence, operationId: operationId, attemptId: attempt.id)
                return .rejected
            }
            guard let plan = editor.shotPlan else { return .stopped }
            var segments: [(shotId: String, sourceRange: ShotSourceRange)] = []
            var cursor = 0.0
            for (index, destination) in initial.destinations.enumerated() {
                guard let planned = destination.plannedSeconds, planned.isFinite, planned > 0 else {
                    throw ToolError("Operation has no saved beat timing. Bind the retained take manually.")
                }
                let end = index == initial.destinations.count - 1 ? asset.duration : cursor + planned
                guard end.isFinite, end > cursor, end <= asset.duration else { throw ToolError("Generated video does not cover every beat.") }
                let range = ShotSourceRange(startSeconds: cursor, endSeconds: end)
                segments.append((destination.shotId, range))
                recordTake(shotId: destination.shotId, asset: asset, model: attempt.recipe.model,
                           unitId: initial.destinations.count > 1 ? initial.id : nil, sourceRange: range, operationId: operationId)
                if initial.autoQA || reason?.isEmpty == false {
                    let previous = evidence.reviews.first { $0.shotId == destination.shotId && $0.sourceRange == range && $0.passed }
                    if previous == nil {
                        let overridden = reason?.isEmpty == false
                        let qaModel = VisionQA.selectModel()
                        let result: VisionQA.Result?
                        if overridden { result = nil }
                        else {
                            result = await runAutoQA(shotId: destination.shotId, asset: asset, plan: plan,
                                                    operationId: operationId, runId: runId, sourceRange: range, qaModel: qaModel)
                        }
                        guard finalizationIsCurrent(operationId, runId: runId) else { return .stopped }
                        let prior = evidence.reviews.first { $0.shotId == destination.shotId && $0.sourceRange == range }
                        let review = ProductionFinalization.Review(shotId: destination.shotId, sourceRange: range,
                            reviewer: overridden ? "user" : (evaluateVideoQA == nil ? qaModel ?? "unavailable" : "injected"),
                            passed: result?.pass == true || overridden,
                            summary: overridden ? prior?.summary ?? "Manual review" : result?.summary ?? "QA unavailable",
                            reviewedAt: Date(), approvalReason: overridden ? reason : nil, qaPassed: overridden ? prior?.qaPassed : result?.pass)
                        evidence.reviews.removeAll { $0.shotId == destination.shotId }
                        evidence.reviews.append(review)
                        storeFinalization(evidence, operationId: operationId, attemptId: attempt.id)
                        guard review.passed else { return result == nil ? .unchecked : .rejected }
                    }
                }
                cursor = end
            }
            try await editor.checkpointProductionState()
            let finalDigest = try await outputDigest(asset)
            guard finalizationIsCurrent(operationId, runId: runId) else { return .stopped }
            guard finalDigest == digest else { throw ToolError("Video changed during review. Validate and review its current bytes before placement.") }
            try editor.placeProductionUnit(asset: asset, segments: segments)
            for segment in segments { evidence.placements[segment.shotId] = editor.shot(id: segment.shotId)?.placement }
            storeFinalization(evidence, operationId: operationId, attemptId: attempt.id)
            editor.mutateProductionOperation(operationId) { $0.stage = .placed; $0.failureReason = nil }
            editor.reorderProductionClipsToPlanOrder()
            try await editor.checkpointProductionState()
            return .placed
        } catch {
            guard acceptsSubmissions(runId: runId) else { return .stopped }
            editor.mutateProductionOperation(operationId) { $0.failureReason = error.localizedDescription }
            return .unchecked
        }
    }

    private func storeFinalization(_ evidence: ProductionFinalization, operationId: String, attemptId: String) {
        editor?.mutateProductionOperation(operationId) { operation in
            guard let index = operation.attempts.firstIndex(where: { $0.id == attemptId }) else { return }
            operation.attempts[index].finalization = evidence
        }
    }
}
