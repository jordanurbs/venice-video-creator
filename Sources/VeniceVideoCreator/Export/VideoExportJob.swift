import Foundation

struct VideoExportJob: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case queued, preparing, rendering, verifying, publishing, completed, failed, cancelled, interrupted
        var isTerminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
    }

    struct Artifact: Codable, Sendable, Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var durationSeconds: Double
        var videoFrames: Int
        var audioTracks: Int
        var decodedAudioSamples: Int
        var bytes: Int
        var sha256: String
    }

    var id = UUID().uuidString
    var createdAt = Date()
    var updatedAt = Date()
    var status: Status = .queued
    var revision: String
    var path: String
    var codec: String
    var resolution: String
    var timeline: Timeline
    var sourceDigests: [String: String]
    var warnings: [String]
    var artifact: Artifact?
    var error: String?

    struct Summary: Encodable {
        var jobId: String
        var status: Status
        var revision: String
        var path: String
        var codec: String
        var resolution: String
        var fps: Int
        var durationFrames: Int
        var progress: Double
        var warnings: [String]
        var artifact: Artifact?
        var error: String?
        var updatedAt: Date

        init(_ job: VideoExportJob, progress: Double) {
            jobId = job.id; status = job.status; revision = job.revision; path = job.path
            codec = job.codec; resolution = job.resolution; fps = job.timeline.fps
            durationFrames = job.timeline.totalFrames; self.progress = progress
            warnings = job.warnings; artifact = job.artifact; error = job.error; updatedAt = job.updatedAt
        }
    }
}
