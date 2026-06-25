import Foundation

/// Thin client for the Venice.ai REST API (OpenAI-compatible).
///
/// One Venice key powers every AI feature. This type only builds requests and
/// performs transport; higher-level flows (generation job runner, agent client,
/// model catalog) live in sibling files.
struct VeniceAPI: Sendable {
    static let baseURL = URL(string: "https://api.venice.ai/api/v1")!

    let apiKey: String

    /// Builds a `VeniceAPI` from the key stored in the Keychain, or `nil` when
    /// the user hasn't entered one yet.
    static func fromKeychain() -> VeniceAPI? {
        guard let key = VeniceKeychain.load(), !key.isEmpty else { return nil }
        return VeniceAPI(apiKey: key)
    }

    enum VeniceError: LocalizedError {
        case missingKey
        case http(status: Int, message: String)
        case transport(String)
        case decode(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingKey: return "No Venice API key set. Add your key in Settings."
            case .http(let status, let message):
                return message.isEmpty ? "Venice API error (HTTP \(status))." : message
            case .transport(let m): return m
            case .decode(let m): return "Venice response error: \(m)"
            case .empty: return "Venice returned an empty response."
            }
        }
    }

    // MARK: - Request building

    func makeRequest(
        path: String,
        method: String = "POST",
        accept: String = "application/json",
        body: Data? = nil
    ) -> URLRequest {
        // Build by string concatenation so query strings (e.g. "models?type=all")
        // are preserved — `appendingPathComponent` would percent-encode the "?".
        let url = URL(string: Self.baseURL.absoluteString + "/" + path) ?? Self.baseURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    // MARK: - JSON helpers

    /// POST a JSON object and decode the JSON response into a dictionary.
    func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        let request = makeRequest(path: path, body: try jsonBody(body))
        let (data, response) = try await data(for: request)
        try Self.assertOK(data: data, response: response)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VeniceError.decode("expected a JSON object")
        }
        return obj
    }

    /// GET a path and decode the JSON response into a dictionary.
    func getJSON(path: String) async throws -> [String: Any] {
        let request = makeRequest(path: path, method: "GET")
        let (data, response) = try await data(for: request)
        try Self.assertOK(data: data, response: response)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VeniceError.decode("expected a JSON object")
        }
        return obj
    }

    // MARK: - Transport

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw VeniceError.transport(error.localizedDescription)
        }
    }

    static func assertOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VeniceError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VeniceError.http(status: http.statusCode, message: extractError(from: data))
        }
    }

    /// Pulls a human-readable message out of Venice's error envelopes.
    static func extractError(from data: Data) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
        }
        if let error = obj["error"] as? String { return error }
        if let error = obj["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
        }
        if let message = obj["message"] as? String { return message }
        if let detail = obj["detail"] as? String { return detail }
        return String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
    }
}
