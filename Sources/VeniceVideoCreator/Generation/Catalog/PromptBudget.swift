import Foundation

/// Positive-prompt length budgets for image models. Venice image models quietly
/// ignore or drop detail past a model-specific length, so front-loading the subject
/// and key style cue produces more faithful results. Values mirror the production
/// video harness. Matching is by family substring so it survives live-catalog id
/// drift; unknown models fall back to a conservative cap. This is advisory only —
/// it never blocks or truncates a generation.
enum PromptBudget {
    static let fallbackChars = 300

    private static let familyCaps: [(needle: String, cap: Int)] = [
        ("gpt-image", 600),
        ("nano-banana", 500),
        ("seedream", 300),
    ]

    static func maxChars(forModelId id: String) -> Int {
        let lower = id.lowercased()
        for entry in familyCaps where lower.contains(entry.needle) {
            return entry.cap
        }
        return fallbackChars
    }

    /// A non-blocking warning when a prompt exceeds the model's budget, or nil.
    static func warning(prompt: String, modelId: String, modelName: String) -> String? {
        let count = prompt.trimmingCharacters(in: .whitespacesAndNewlines).count
        let cap = maxChars(forModelId: modelId)
        guard count > cap else { return nil }
        return "Prompt is \(count) characters; \(modelName) works best under \(cap). "
            + "Extra detail may be dropped — trim it or move the essentials to the front."
    }
}
