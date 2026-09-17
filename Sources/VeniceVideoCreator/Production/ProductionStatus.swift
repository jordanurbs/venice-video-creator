import Foundation

struct ProductionStatus: Encodable {
    let isRunning: Bool
    let isPaused: Bool
    let currentShotId: String?
    let succeededCount: Int
    let failedCount: Int
    let cancelledCount: Int
    let totalCount: Int
    let queuedUnits: [MultiShotPlanner.Unit]
    let generatingShotIds: [String]
    let runningUSD: Double
    let lastError: String?
    var operationCount: Int = 0
    var operations: [OperationSummary] = []
    var audioOperationCount: Int = 0
    var audioOperations: [AudioSummary] = []

    struct AudioSummary: Encodable {
        let id: String
        let key: ProductionAudioOperation.Key
        let stage: ProductionAudioOperation.Stage
        let clipId: String
        let assetId: String?
        let queueId: String?
        let measuredSeconds: Double?
        let failureReason: String?

        init(_ operation: ProductionAudioOperation) {
            id = operation.id; key = operation.key; stage = operation.stage; clipId = operation.clipId
            assetId = operation.placeholderId; queueId = operation.queueId
            measuredSeconds = operation.measuredSeconds; failureReason = operation.failureReason
        }
    }

    struct OperationSummary: Encodable {
        let id: String
        let stage: ProductionOperation.Stage
        let shotIds: [String]
        let attemptCount: Int
        let attemptId: String?
        let placeholderId: String?
        let queueId: String?
        let failureReason: String?
        let contentDigest: String?
        let reviews: [ProductionFinalization.Review]

        init(_ operation: ProductionOperation) {
            id = operation.id
            stage = operation.stage
            shotIds = operation.destinations.map(\.shotId)
            attemptCount = operation.attempts.count
            attemptId = operation.attempts.last?.id
            placeholderId = operation.attempts.last?.placeholderId
            queueId = operation.attempts.last?.queueId
            failureReason = operation.failureReason ?? operation.attempts.last?.failureReason
            contentDigest = operation.attempts.last?.finalization?.contentDigest
            reviews = operation.attempts.last?.finalization?.reviews ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case isRunning, isPaused, currentShotId, completedCount, succeededCount, failedCount
        case cancelledCount, settledCount, pendingCount, totalCount, queuedCount, queuedUnitCount
        case queuedShotIds, queuedUnits, generatingShotIds, runningUSD, lastError
        case operationCount, operations, audioOperationCount, audioOperations
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let queuedShotIds = queuedUnits.flatMap(\.shotIds)
        let settled = succeededCount + failedCount + cancelledCount
        try c.encode(isRunning, forKey: .isRunning)
        try c.encode(isPaused, forKey: .isPaused)
        try c.encode(currentShotId, forKey: .currentShotId)
        try c.encode(succeededCount, forKey: .completedCount)
        try c.encode(succeededCount, forKey: .succeededCount)
        try c.encode(failedCount, forKey: .failedCount)
        try c.encode(cancelledCount, forKey: .cancelledCount)
        try c.encode(settled, forKey: .settledCount)
        try c.encode(max(0, totalCount - settled), forKey: .pendingCount)
        try c.encode(totalCount, forKey: .totalCount)
        try c.encode(queuedShotIds.count, forKey: .queuedCount)
        try c.encode(queuedUnits.count, forKey: .queuedUnitCount)
        try c.encode(queuedShotIds, forKey: .queuedShotIds)
        try c.encode(queuedUnits, forKey: .queuedUnits)
        try c.encode(generatingShotIds, forKey: .generatingShotIds)
        try c.encode(runningUSD, forKey: .runningUSD)
        try c.encode(lastError, forKey: .lastError)
        try c.encode(operationCount, forKey: .operationCount)
        try c.encode(operations, forKey: .operations)
        try c.encode(audioOperationCount, forKey: .audioOperationCount)
        try c.encode(audioOperations, forKey: .audioOperations)
    }
}
