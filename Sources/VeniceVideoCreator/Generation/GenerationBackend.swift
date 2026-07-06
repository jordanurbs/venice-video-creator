import Foundation
import Combine

/// Venice-backed generation backend.
///
/// Replaces the original Convex/Venice cloud backend. The public surface is
/// unchanged so `GenerationService` keeps working: `submit` kicks off a job and
/// returns an id, `subscribe` exposes job updates as a Combine publisher, and
/// `uploadReference` turns a local file into something Venice can ingest.
///
/// Because this is a local BYO-key app, reference media is inlined as a base64
/// `data:` URL rather than uploaded to remote storage.
@MainActor
enum GenerationBackend {
    private static let store = VeniceJobStore()

    /// Jobs still queued or running; consulted by the quit guard.
    static var activeJobCount: Int { store.activeCount }

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
        // Encoding a video reference can be hundreds of MB; keep it off the main actor.
        let encoded = try await Task.detached(priority: .utility) {
            try Data(contentsOf: fileURL).base64EncodedString()
        }.value
        return "data:\(contentType);base64,\(encoded)"
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

    /// Re-polls a queued Venice job by its persisted queue id and returns a fresh local id.
    static func resume(
        queueId: String,
        model: String,
        kind: VeniceQueueKind,
        downloadURL: String?
    ) throws -> String {
        guard let api = VeniceAPI.fromKeychain() else {
            throw GenerationBackendError.notConfigured
        }
        return store.resume(queueId: queueId, model: model, kind: kind, downloadURL: downloadURL, api: api)
    }

    /// Cancels a tracked job's poll task. Returns false if the job is unknown.
    @discardableResult
    static func cancel(jobId: String) -> Bool {
        store.cancel(jobId: jobId)
    }
}

// MARK: - Backend generation types

enum BackendGenerationParams: Encodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)
    case imageEdit(ImageEditParams)
    case imageMultiEdit(ImageMultiEditParams)
    case backgroundRemove(BackgroundRemoveParams)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .video(let p): try c.encode(p)
        case .image(let p): try c.encode(p)
        case .audio(let p): try c.encode(p)
        case .upscale(let p): try c.encode(p)
        case .imageEdit(let p): try c.encode(p)
        case .imageMultiEdit(let p): try c.encode(p)
        case .backgroundRemove(let p): try c.encode(p)
        }
    }
}

enum BackendGenerationStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed, cancelled
}

struct BackendGenerationJob: Decodable, Sendable {
    let _id: String
    let status: BackendGenerationStatus
    let resultUrls: [String]?
    let errorMessage: String?
    let costCredits: Int?
    let completedAt: Double?
    let queueId: String?
    let queueDownloadURL: String?

    init(
        id: String,
        status: BackendGenerationStatus,
        resultUrls: [String]? = nil,
        errorMessage: String? = nil,
        costCredits: Int? = nil,
        completedAt: Double? = nil,
        queueId: String? = nil,
        queueDownloadURL: String? = nil
    ) {
        self._id = id
        self.status = status
        self.resultUrls = resultUrls
        self.errorMessage = errorMessage
        self.costCredits = costCredits
        self.completedAt = completedAt
        self.queueId = queueId
        self.queueDownloadURL = queueDownloadURL
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
    private var tasks: [String: Task<Void, Never>] = [:]

    /// In-flight jobs; a task is removed the moment its job settles.
    var activeCount: Int { tasks.count }

    func publisher(for jobId: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        subjects[jobId]?.eraseToAnyPublisher()
    }

    func start(model: String, params: BackendGenerationParams, api: VeniceAPI) -> String {
        let jobId = UUID().uuidString
        let subject = CurrentValueSubject<BackendGenerationJob?, Never>(
            BackendGenerationJob(id: jobId, status: .queued)
        )
        subjects[jobId] = subject

        tasks[jobId] = Task { @MainActor in
            subject.send(BackendGenerationJob(id: jobId, status: .running))
            await self.settle(jobId: jobId, subject: subject) {
                try await VeniceGenerationRunner.run(model: model, params: params, api: api) { queueId, downloadURL in
                    subject.send(BackendGenerationJob(id: jobId, status: .running,
                                                      queueId: queueId, queueDownloadURL: downloadURL))
                }
            }
        }
        return jobId
    }

    func resume(
        queueId: String,
        model: String,
        kind: VeniceQueueKind,
        downloadURL: String?,
        api: VeniceAPI
    ) -> String {
        let jobId = UUID().uuidString
        let subject = CurrentValueSubject<BackendGenerationJob?, Never>(
            BackendGenerationJob(id: jobId, status: .running, queueId: queueId, queueDownloadURL: downloadURL)
        )
        subjects[jobId] = subject

        tasks[jobId] = Task { @MainActor in
            await self.settle(jobId: jobId, subject: subject) {
                try await VeniceGenerationRunner.resume(
                    queueId: queueId, model: model, kind: kind, downloadURL: downloadURL, api: api
                )
            }
        }
        return jobId
    }

    @discardableResult
    func cancel(jobId: String) -> Bool {
        guard let task = tasks[jobId] else { return false }
        task.cancel()
        return true
    }

    private func settle(
        jobId: String,
        subject: CurrentValueSubject<BackendGenerationJob?, Never>,
        operation: @MainActor () async throws -> [String]
    ) async {
        do {
            let urls = try await operation()
            subject.send(BackendGenerationJob(id: jobId, status: .succeeded, resultUrls: urls,
                                              completedAt: Date().timeIntervalSince1970))
        } catch {
            // VeniceAPI wraps URLError, so a cancelled request surfaces as .transport;
            // the task's own cancellation flag is the reliable signal.
            if Task.isCancelled || error is CancellationError {
                subject.send(BackendGenerationJob(id: jobId, status: .cancelled))
            } else {
                subject.send(BackendGenerationJob(id: jobId, status: .failed,
                                                  errorMessage: error.localizedDescription))
            }
        }
        tasks[jobId] = nil
        // Allow late subscribers one cycle, then release.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.subjects[jobId] = nil
        }
    }
}
