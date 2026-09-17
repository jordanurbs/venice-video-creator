import Foundation

enum ProductionModelSelection {
    static func resolve(_ id: String?, in available: [VideoModelConfig]) throws -> VideoModelConfig? {
        guard let id else { return nil }
        guard let model = available.first(where: { $0.id == id }) else {
            throw ToolError("Video model '\(id)' is unavailable or disabled. Refresh Models in Settings, then select an available model. No substitute was submitted.")
        }
        guard !model.requiresSourceVideo else {
            throw ToolError("\(model.displayName) requires a source video. Select a text-, image-, or reference-to-video model for shot production.")
        }
        return model
    }
}
