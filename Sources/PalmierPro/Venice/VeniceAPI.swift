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

    /// Builds a `multipart/form-data` request. `fields` are simple text parts;
    /// `file` is an optional binary part with filename + content type.
    func makeMultipartRequest(
        path: String,
        fields: [String: String] = [:],
        file: (field: String, filename: String, contentType: String, data: Data)? = nil,
        accept: String = "application/json"
    ) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        if let file {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        let url = URL(string: Self.baseURL.absoluteString + "/" + path) ?? Self.baseURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
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

    // MARK: - Cost quotes (USD)

    /// Estimated USD cost for a video generation, via Venice's `/video/quote`.
    func videoQuote(model: String, duration: Int, resolution: String?, aspectRatio: String) async -> Double? {
        var body: [String: Any] = ["model": model, "duration": "\(max(1, duration))s"]
        if let resolution, !resolution.isEmpty { body["resolution"] = resolution }
        if !aspectRatio.isEmpty { body["aspect_ratio"] = aspectRatio }
        return (try? await postJSON(path: "video/quote", body: body))?["quote"] as? Double
    }

    /// Estimated USD cost for an audio generation, via Venice's `/audio/quote`.
    func audioQuote(model: String, durationSeconds: Int?, characterCount: Int?) async -> Double? {
        var body: [String: Any] = ["model": model]
        if let durationSeconds, durationSeconds > 0 { body["duration_seconds"] = durationSeconds }
        if let characterCount, characterCount > 0 { body["character_count"] = characterCount }
        return (try? await postJSON(path: "audio/quote", body: body))?["quote"] as? Double
    }

    /// Pulls a human-readable message out of Venice's error envelopes.
    static func extractError(from data: Data) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
        }
        var base = ""
        if let error = obj["error"] as? String { base = error }
        else if let error = obj["error"] as? [String: Any], let message = error["message"] as? String { base = message }
        else if let message = obj["message"] as? String { base = message }
        else if let detail = obj["detail"] as? String { base = detail }
        // Venice returns Zod-style field diagnostics under `issues`; surface them so
        // the message is actionable instead of a generic "Invalid request parameters".
        let issues = (obj["issues"] as? [[String: Any]])?.compactMap { issue -> String? in
            let msg = issue["message"] as? String
            let path = (issue["path"] as? [Any])?.map { "\($0)" }.joined(separator: ".")
            switch (path, msg) {
            case let (p?, m?) where !p.isEmpty: return "\(p): \(m)"
            case let (_, m?): return m
            default: return nil
            }
        } ?? []
        if !issues.isEmpty {
            let joined = Array(Set(issues)).sorted().joined(separator: " | ")
            base = base.isEmpty ? joined : "\(base) (\(joined))"
        }
        if base.isEmpty { base = String(data: data, encoding: .utf8)?.prefix(300).description ?? "" }
        return base
    }
}
