import Foundation

/// Error type surfaced by the agent stream. Originally tied to the Palmier cloud
/// backend; retained as the shared agent error type now that streaming runs
/// directly against Venice.
enum AgentClientError: LocalizedError {
    case unauthenticated
    case insufficientCredits(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .unauthenticated: "Add your Venice API key in Settings to use the AI agent."
        case .insufficientCredits(let m): m
        case .upstream(let m): m
        }
    }

    static func from(status: Int, body: String) -> AgentClientError {
        let parsed = parseErrorEnvelope(body)
        // Unparseable bodies are HTML dumps or truncated JSON — never show them raw.
        let message = parsed?.message ?? ""
        switch parsed?.code {
        case "unauthenticated": return .unauthenticated
        case "insufficient_credits":
            return .insufficientCredits(message.isEmpty ? "Venice account is out of credit. Top up at venice.ai." : message)
        default:
            if status == 401 { return .unauthenticated }
            if status == 402 {
                return .insufficientCredits(message.isEmpty ? "Venice account is out of credit. Top up at venice.ai." : message)
            }
            return .upstream(message.isEmpty ? "Venice error (HTTP \(status)). Try again." : message)
        }
    }

    private static func parseErrorEnvelope(_ body: String) -> (code: String, message: String)? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let code = err["code"] as? String,
              let message = err["message"] as? String
        else { return nil }
        return (code, message)
    }
}
