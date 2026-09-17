import Foundation

struct CameraTrajectory: Codable, Sendable, Equatable {
    struct Keyframe: Codable, Sendable, Equatable {
        var time: Double
        var azimuth: Double
        var elevation: Double
        var distance: Double
    }

    var keyframes: [Keyframe]

    static let stationary = CameraTrajectory(keyframes: [
        .init(time: 0, azimuth: 0, elevation: 0, distance: 1),
        .init(time: 1, azimuth: 0, elevation: 0, distance: 1),
    ])

    init(keyframes: [Keyframe]) { self.keyframes = keyframes }

    init(from decoder: Decoder) throws {
        keyframes = try decoder.singleValueContainer().decode([Keyframe].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(keyframes)
    }

    var validationError: String? {
        guard (2...12).contains(keyframes.count) else { return "Camera move requires 2–12 keyframes." }
        var travel = 0.0
        for (index, frame) in keyframes.enumerated() {
            guard [frame.time, frame.azimuth, frame.elevation, frame.distance].allSatisfy(\.isFinite) else {
                return "Camera keyframe \(index + 1) requires finite values."
            }
            guard (0...1).contains(frame.time) else { return "Camera keyframe time must be between 0 and 1." }
            guard (-90...90).contains(frame.elevation) else { return "Camera elevation must be between −90° and 90°." }
            guard frame.distance > 0 else { return "Camera distance must be greater than 0 (1 is unchanged)." }
            if index > 0 {
                let previous = keyframes[index - 1]
                guard frame.time > previous.time else { return "Camera keyframe times must strictly increase." }
                travel += abs(frame.azimuth - previous.azimuth)
            }
        }
        guard travel.isFinite, travel <= 11_520 else { return "Camera azimuth travel must not exceed 11,520° (32 turns)." }
        return nil
    }

    static func validate(_ trajectory: Self?, modelID: String) -> String? {
        guard VideoModelCapabilities.supportsCameraTrajectory(id: modelID) else {
            return trajectory == nil ? nil : "Model '\(modelID)' does not support camera_trajectory. Select Multi-Angle or remove the camera move."
        }
        guard let trajectory else { return "Set the camera move before generating with Multi-Angle." }
        return trajectory.validationError
    }
}
