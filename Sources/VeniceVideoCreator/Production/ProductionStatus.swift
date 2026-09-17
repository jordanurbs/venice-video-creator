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
        case operationCount, operations
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
    }
}
