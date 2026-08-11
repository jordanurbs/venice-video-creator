import SwiftUI

/// Animated "thinking" indicator for the agent panel.
///
/// Deliberately uses `TimelineView` rather than `Timer.publish(...).autoconnect()`
/// + `onReceive`: the Combine timer held as a view property outlives the view's
/// attribute-graph node when the panel churns (which it does on every tool call
/// during a production run), and a tick landing after teardown crashes in
/// `SubscriptionView.Subscriber.updateValue` (EXC_BAD_ACCESS — seen 2026-08-06).
/// TimelineView's schedule is owned and cancelled by SwiftUI itself.
struct ThinkingDots: View {
    private static let stepDuration: TimeInterval = 0.28

    var body: some View {
        // Fully qualified: the app has its own `TimelineView` (video timeline).
        SwiftUI.TimelineView(.periodic(from: .now, by: Self.stepDuration)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / Self.stepDuration) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(AppTheme.Text.tertiaryColor)
                        .frame(width: 5, height: 5)
                        .opacity(phase == i ? 1 : 0.25)
                        .animation(.easeInOut(duration: 0.25), value: phase)
                }
            }
        }
    }
}
