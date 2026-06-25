import Foundation
import Combine

/// Venice-backed generation backend.
///
/// Replaces the original Convex/Palmier cloud backend. The public surface is
/// unchanged so `GenerationService` keeps working: `submit` kicks off a job and
/// returns an id, `subscribe` exposes job updates as a Combine publisher, and
/// `uploadReference` turns a local file into something Venice can ingest.
///
/// Because this is a local BYO-key app, reference media is inlined as a base64
/// `data:` URL rather than uploaded to remote storage.
@MainActor
enum GenerationBackend {
    private static let store = VeniceJobStore()

    /// Reactive subscription to a single generation job.
    static func subscribe(
        jobId: String
    ) -> AnyPublisher<BackendGenerationJob?, Never>? {
        store.publisher(for: jobId)
    }

    /// Inlines a local file as a base64 `data:` URL. No remote upload needed.
    static func uploadReference(
        fileURL: URL,
        contentType: String
    ) async throws -> String {
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: fileURL)
        }.value
        return "data:\(contentType);base64,\(data.base64EncodedString())"
    }

    /// Starts a Venice generation job and returns its local id.
    static func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String? = nil
    ) async throws -> String {
        guard let api = VeniceAPI.fromKeychain() else {
            throw GenerationBackendError.notConfigured
        }
        return store.start(model: model, params: params, api: api)
    }
}

// MARK: - Backend generation types

enum BackendGenerationParams: Encodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .video(let p): try c.encode(p)
        case .image(let p): try c.encode(p)
        case .audio(let p): try c.encode(p)
        case .upscale(let p): try c.encode(p)
        }
    }
}

enum BackendGenerationStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendGenerationJob: Decodable, Sendable {
    let _id: String
    let status: BackendGenerationStatus
    let resultUrls: [String]?
    let errorMessage: String?
    let costCredits: Int?
    let completedAt: Double?

    init(
        id: String,
        status: BackendGenerationStatus,
        resultUrls: [String]? = nil,
        errorMessage: String? = nil,
        costCredits: Int? = nil,
        completedAt: Double? = nil
    ) {
        self._id = id
        self.status = status
        self.resultUrls = resultUrls
        self.errorMessage = errorMessage
        self.costCredits = costCredits
        self.completedAt = completedAt
    }
}

enum GenerationBackendError: LocalizedError {
    case notConfigured
    case transport(String)
    case api(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Venice API key set. Add your key in Settings to generate."
        case .transport(let s): return s
        case .api(_, _, let message): return message
        }
    }
}

// MARK: - Job store

/// Tracks in-flight Venice generation jobs and publishes their status updates.
@MainActor
final class VeniceJobStore {
    private var subjects: [String: CurrentValueSubject<BackendGenerationJob?, Never>] = [:]

    func publisher(for jobId: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        subjects[jobId]?.eraseToAnyPublisher()
    }

    func start(model: String, params: BackendGenerationParams, api: VeniceAPI) -> String {
        let jobId = UUID().uuidString
        let subject = CurrentValueSubject<BackendGenerationJob?, Never>(
            BackendGenerationJob(id: jobId, status: .queued)
        )
        subjects[jobId] = subject

        Task { @MainActor in
            subject.send(BackendGenerationJob(id: jobId, status: .running))
            do {
                let urls = try await VeniceGenerationRunner.run(model: model, params: params, api: api)
                subject.send(BackendGenerationJob(id: jobId, status: .succeeded, resultUrls: urls,
                                                  completedAt: Date().timeIntervalSince1970))
            } catch {
                subject.send(BackendGenerationJob(id: jobId, status: .failed,
                                                  errorMessage: error.localizedDescription))
            }
            // Allow late subscribers one cycle, then release.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.subjects[jobId] = nil
            }
        }
        return jobId
    }
}
