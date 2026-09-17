import Foundation

struct ProductionOperation: Codable, Sendable, Equatable, Identifiable {
    enum Stage: String, Codable, Sendable {
        case preparing, generating, validating, reviewing, placed, failed, cancelled, interrupted
        var isTerminal: Bool { self == .placed || self == .failed || self == .cancelled || self == .interrupted }
    }
    struct Destination: Codable, Sendable, Equatable {
        let shotId: String
        let settingsDigest: String
        let placement: ShotPlacement?
        var plannedSeconds: Double?
        var storyboardRevision: StoryboardRevision?
    }
    struct Attempt: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let takeIds: [String: String]
        let recipe: GenerationInput
        let createdAt: Date
        var placeholderId: String?
        var backendJobId: String?
        var queueId: String?
        var generationStatus: String?
        var failureReason: String?
        var finalization: ProductionFinalization?
    }
    let id: String
    let runId: UUID
    let destinations: [Destination]
    let autoQA: Bool
    let createdAt: Date
    var stage: Stage = .preparing
    var attempts: [Attempt] = []
    var failureReason: String?
    var seed: Int?
}

extension EditorViewModel {
    func beginProductionOperation(shotIds: [String], runId: UUID, autoQA: Bool) throws -> String {
        guard productionOrchestrator.acceptsSubmissions(runId: runId) else { throw ToolError("Production run was superseded.") }
        guard let plan = shotPlan else { throw ToolError("No shot plan yet.") }
        guard !shotIds.isEmpty, Set(shotIds).count == shotIds.count else { throw ToolError("Production requires unique shot IDs.") }
        let destinations = try shotIds.map { id in
            guard let shot = plan.shot(id: id) else { throw ToolError("Shot not found: \(id)") }
            return ProductionOperation.Destination(shotId: id, settingsDigest: try StoryboardReviewGate.settingsDigest(shot: shot, plan: plan),
                                                   placement: try productionPlacement(for: shot), plannedSeconds: shot.durationSeconds,
                                                   storyboardRevision: try requireApprovedStoryboard(for: shot, plan: plan))
        }
        let id = UUID().uuidString
        var operation = ProductionOperation(id: id, runId: runId, destinations: destinations, autoQA: autoQA, createdAt: Date())
        operation.seed = plan.seed
        mediaManifest.productionOperations.append(operation)
        for index in mediaManifest.shotPlan!.shots.indices where shotIds.contains(mediaManifest.shotPlan!.shots[index].id) {
            mediaManifest.shotPlan!.shots[index].activeProductionOperationId = id
        }
        onProjectContentChanged?()
        return id
    }

    func productionOperation(id: String) -> ProductionOperation? { mediaManifest.productionOperations.first { $0.id == id } }

    func requireCurrentProductionOperation(_ id: String) throws -> ProductionOperation {
        guard let operation = productionOperation(id: id), !operation.stage.isTerminal,
              productionOrchestrator.acceptsSubmissions(runId: operation.runId) else {
            throw ToolError("Production operation was cancelled, interrupted, or superseded.")
        }
        return try requireProductionDestination(id)
    }

    func requireProductionDestination(_ id: String) throws -> ProductionOperation {
        guard let operation = productionOperation(id: id), let plan = shotPlan, operation.seed == plan.seed else {
            throw ToolError("Production settings changed. Review the current shot plan before finalizing this take.")
        }
        for destination in operation.destinations {
            guard let shot = plan.shot(id: destination.shotId), shot.activeProductionOperationId == id,
                  try StoryboardReviewGate.settingsDigest(shot: shot, plan: plan) == destination.settingsDigest,
                  try requireApprovedStoryboard(for: shot, plan: plan) == destination.storyboardRevision,
                  try productionPlacement(for: shot) == destination.placement else {
                throw ToolError("The shot or its destination changed during production. Start a new operation for the current revision.")
            }
        }
        return operation
    }

    func beginProductionAttempt(operationId: String, recipe: GenerationInput) throws -> GenerationInput {
        let operation = try requireCurrentProductionOperation(operationId)
        if let attemptId = operation.attempts.last?.id, productionOrchestrator.finalizingAttemptIds.contains(attemptId) {
            throw ToolError("Wait for the current attempt to finish finalizing before retrying generation.")
        }
        let id = UUID().uuidString
        var input = recipe
        input.productionOperationId = operationId
        input.productionAttemptId = id
        let takeIds = Dictionary(uniqueKeysWithValues: operation.destinations.map { ($0.shotId, UUID().uuidString) })
        mutateProductionOperation(operationId) {
            $0.attempts.append(.init(id: id, takeIds: takeIds, recipe: input, createdAt: Date()))
            $0.stage = .generating
        }
        return input
    }

    func validateProductionAttempt(_ input: GenerationInput, placeholderId: String? = nil) throws {
        guard let operationId = input.productionOperationId else { return }
        let operation = try requireCurrentProductionOperation(operationId)
        guard let attemptId = input.productionAttemptId, operation.attempts.last?.id == attemptId else {
            throw ToolError("Production attempt was superseded.")
        }
        if let placeholderId, operation.attempts.last?.placeholderId != placeholderId {
            throw ToolError("Production attempt belongs to another placeholder. Create a new attempt before generating.")
        }
    }

    func mutateProductionOperation(_ id: String, _ mutate: (inout ProductionOperation) -> Void) {
        guard let index = mediaManifest.productionOperations.firstIndex(where: { $0.id == id }) else { return }
        let before = mediaManifest.productionOperations[index]
        mutate(&mediaManifest.productionOperations[index])
        guard mediaManifest.productionOperations[index] != before else { return }
        onProjectContentChanged?()
        onProjectCheckpointRequired?()
    }

    func recordProductionJobMetadata(_ asset: MediaAsset) {
        guard let input = asset.generationInput, let operationId = input.productionOperationId,
              let attemptId = input.productionAttemptId else { return }
        mutateProductionOperation(operationId) { operation in
            guard let index = operation.attempts.firstIndex(where: { $0.id == attemptId }) else { return }
            guard operation.attempts[index].placeholderId == nil || operation.attempts[index].placeholderId == asset.id else { return }
            operation.attempts[index].placeholderId = asset.id
            operation.attempts[index].backendJobId = input.backendJobId
            operation.attempts[index].queueId = input.queueId
            operation.attempts[index].generationStatus = asset.generationStatus.serialized
            if case .failed(let reason) = asset.generationStatus { operation.attempts[index].failureReason = reason }
        }
    }

    func checkpointProductionState() async throws {
        guard let persistProductionState else { throw ToolError("Save the project before producing so operation records can be recovered.") }
        try await persistProductionState()
    }

    func recordProductionAttemptFailure(_ operationId: String, reason: String) {
        mutateProductionOperation(operationId) { operation in
            guard let index = operation.attempts.indices.last else { return }
            operation.attempts[index].failureReason = reason
        }
    }

    func settleProductionOperations(runId: UUID, stage: ProductionOperation.Stage) {
        var changed = false
        for index in mediaManifest.productionOperations.indices {
            guard mediaManifest.productionOperations[index].runId == runId,
                  !mediaManifest.productionOperations[index].stage.isTerminal else { continue }
            mediaManifest.productionOperations[index].stage = stage
            changed = true
        }
        guard changed else { return }
        onProjectContentChanged?()
        onProjectCheckpointRequired?()
    }
}
