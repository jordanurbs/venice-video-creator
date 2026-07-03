import Foundation

extension ToolExecutor {
    // send_feedback's diagnostics trail + per-session dedupe; recorded centrally in execute().
    struct FeedbackState {
        private(set) var recentTools: [String] = []
        private(set) var lastError: String?
        var sentKeys: Set<String> = []

        mutating func record(_ result: ToolResult, for tool: ToolName) {
            guard tool != .sendFeedback else { return }
            recentTools.append(tool.rawValue)
            if recentTools.count > 15 { recentTools.removeFirst() }
            if result.isError, case let .text(message)? = result.content.first { lastError = message }
        }
    }

    func resetFeedbackState() { feedbackState = FeedbackState() }

    private static let feedbackCategories: Set<String> = [
        "missing_capability", "wrong_result", "confusing_ux", "failure", "suggestion",
    ]
    private static let feedbackSeverities: Set<String> = ["low", "medium", "high"]
    private static let maxFeedbackPerSession = 8

    func sendFeedback(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let category = try args.requireString("category").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.feedbackCategories.contains(category) else {
            throw ToolError("Invalid category '\(category)'. Expected one of: \(Self.feedbackCategories.sorted().joined(separator: ", ")).")
        }
        let summary = try args.requireString("summary").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw ToolError("summary must not be empty.") }
        let details = args.string("details")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let severity = args.string("severity")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let severity, !Self.feedbackSeverities.contains(severity) {
            throw ToolError("Invalid severity '\(severity)'. Expected low, medium, or high.")
        }

        let dedupeKey = "\(category)|\(summary)"
        guard !feedbackState.sentKeys.contains(dedupeKey) else {
            return .ok("Already flagged this to the team this session — not sending a duplicate.")
        }
        guard feedbackState.sentKeys.count < Self.maxFeedbackPerSession else {
            return .ok("Feedback limit reached for this session. Summarize any remaining issues to the user instead of sending more.")
        }

        // Line 1 (tag + summary) becomes the email subject; category/severity stay in the body.
        var lines = ["[Agent] \(summary)"]
        var classification = "Category: \(category)"
        if let severity { classification += " · \(severity)" }
        lines += ["", classification]
        if let details, !details.isEmpty {
            lines += ["", "Details:", details]
        }
        lines += ["", "Diagnostics (auto-collected):"]
        lines.append("- Recent tools: \(feedbackState.recentTools.isEmpty ? "none" : feedbackState.recentTools.joined(separator: ", "))")
        lines.append("- Last error: \(feedbackState.lastError ?? "none")")
        if let projectId = editor.projectId {
            lines.append("- Project: \(projectId.prefix(8))")
        }

        // No cloud inbox in this build; feedback goes through GitHub issues.
        let url = await FeedbackReporter.issueURL(prefill: lines.joined(separator: "\n"))
        feedbackState.sentKeys.insert(dedupeKey)
        return .ok("There is no in-app feedback channel in this build. Share this prefilled GitHub issue link with the user so they can submit it: \(url.absoluteString)")
    }
}
