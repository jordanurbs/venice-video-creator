import SwiftUI

struct CameraMoveControls: View {
    @Binding var trajectory: CameraTrajectory?
    var supportsCameraMove = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Camera Move")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Spacer()
                if trajectory != nil {
                    Button("Remove") { trajectory = nil }
                        .accessibilityIdentifier("cameraMove.remove")
                }
                if supportsCameraMove {
                    Button("Reset") { trajectory = .stationary }
                        .accessibilityIdentifier("cameraMove.reset")
                }
            }
            if !supportsCameraMove {
                Text("Select Multi-Angle or remove the camera move before generating.")
                    .font(.system(size: AppTheme.FontSize.xxs))
            } else if let frames = trajectory?.keyframes, frames.count >= 2 {
                endpoint("Start", index: 0)
                endpoint("End", index: frames.count - 1)
                if frames.count > 2 {
                    Text("\(frames.count) keyframes. Interior keyframes are preserved.")
                        .font(.system(size: AppTheme.FontSize.xxs))
                }
            } else {
                Button("Set Camera Move") { trajectory = .stationary }
            }
            Text(trajectory?.validationError ?? "Angles in degrees. Distance is relative: 1 is unchanged.")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private func endpoint(_ label: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            field("\(label) horizontal angle (°)", index: index, keyPath: \.azimuth)
            field("\(label) vertical angle (°)", index: index, keyPath: \.elevation)
            field("\(label) relative distance", index: index, keyPath: \.distance)
        }
    }

    private func field(_ label: String, index: Int, keyPath: WritableKeyPath<CameraTrajectory.Keyframe, Double>) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
            TextField(label, value: Binding(
                get: {
                    guard let move = trajectory, move.keyframes.indices.contains(index) else { return 0 }
                    return move.keyframes[index][keyPath: keyPath]
                },
                set: { value in
                    guard var move = trajectory, move.keyframes.indices.contains(index) else { return }
                    move.keyframes[index][keyPath: keyPath] = value
                    trajectory = move
                }
            ), format: .number)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
            .accessibilityIdentifier("cameraMove.\(label)")
        }
    }
}
