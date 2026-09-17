import Foundation

@MainActor
final class VideoGenerationBudget {
    let maximumUSD: Double
    private(set) var reservedUSD = 0.0

    init(maximumUSD: Double) throws {
        guard maximumUSD.isFinite, maximumUSD > 0 else {
            throw ToolError("Set a finite 1080P spending cap greater than zero.")
        }
        self.maximumUSD = maximumUSD
    }

    nonisolated static func isRequired(model: String, resolution: String?) -> Bool {
        model == VideoModelCapabilities.multiAngleID && resolution == "1080P"
    }

    static func requireIfNeeded(model: String, resolution: String?, budget: VideoGenerationBudget?) throws {
        if isRequired(model: model, resolution: resolution), budget == nil {
            throw ToolError("Multi-Angle 1080P requires an explicit spending cap and a fresh quote. Set the 1080P budget in generation settings or pass maxCostUSD with user approval. Reruns require a new budget.")
        }
    }

    static func authorize(
        model: String, params: VideoGenerationParams, budget: VideoGenerationBudget?,
        quote: () async -> Double?
    ) async throws {
        try requireIfNeeded(model: model, resolution: params.resolution, budget: budget)
        guard isRequired(model: model, resolution: params.resolution), let budget else { return }
        if let error = CameraTrajectory.validate(params.cameraTrajectory, modelID: model) { throw ToolError(error) }
        try MiniMaxVideoContract.validate(model: model, params: params)
        try Task.checkCancellation()
        guard let amount = await quote(), amount.isFinite, amount > 0 else {
            throw ToolError("A fresh 1080P quote is unavailable. Refresh the quote before generating.")
        }
        try Task.checkCancellation()
        guard amount <= budget.maximumUSD - budget.reservedUSD else {
            throw ToolError("The fresh 1080P quote exceeds the remaining spending cap. Increase the approved budget or select 768P.")
        }
        // Keep reservations after a send attempt because failed transport can leave billing unknown.
        budget.reservedUSD += amount
    }
}
