import Foundation

struct ProductionAudioOperation: Codable, Sendable, Equatable, Identifiable {
    enum Role: String, Codable, Sendable { case dialogue, music, ambient }
    enum Stage: String, Codable, Sendable { case preparing, generating, ready, placed, failed, cancelled, blocked }
    struct Key: Codable, Sendable, Equatable, Hashable {
        var role: Role
        var shotId: String?
        var lineId: String?
    }

    let id: String
    let key: Key
    let clipId: String
    let recipe: GenerationInput
    let line: ShotDialogue?
    let lockedVoiceId: String?
    let voiceModel: String?
    let pictureClipId: String?
    let requestedFrames: Int
    let fps: Int
    var destination: Clip?
    var ownsTiming: Bool
    var ownsDucking: Bool
    let createdAt: Date
    var stage: Stage = .preparing
    var placeholderId: String?
    var backendJobId: String?
    var queueId: String?
    var generationStatus: String?
    var measuredSeconds: Double?
    var placedClip: Clip?
    var placementFPS: Int?
    var pictureEndFrame: Int?
    var failureReason: String?
}
