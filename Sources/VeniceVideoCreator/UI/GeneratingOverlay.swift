import SwiftUI

struct GeneratingOverlay: View {
    enum Size {
        case thumbnail
        case preview

        var fontSize: CGFloat { self == .preview ? AppTheme.FontSize.xl : AppTheme.FontSize.xs }
        var elapsedFontSize: CGFloat { self == .preview ? AppTheme.FontSize.sm : AppTheme.FontSize.xxs }
        var spacing: CGFloat { self == .preview ? AppTheme.Spacing.lg : AppTheme.Spacing.smMd }
    }

    var label: String = "Generating…"
    var size: Size = .thumbnail

    // Seed from the generation's persisted start so the elapsed clock survives
    // LazyVGrid recycling; nil callers (single, non-recycled overlays) start now.
    @State private var startedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(label: String = "Generating…", size: Size = .thumbnail, startedAt: Date? = nil) {
        self.label = label
        self.size = size
        _startedAt = State(initialValue: startedAt ?? Date())
    }

    var body: some View {
        content
            .shimmering(active: !reduceMotion)
    }

    // Phase label + honest elapsed time; a fake progress bar makes bounded
    // waits (video jobs run to 15 min) read as hangs.
    private var content: some View {
        VStack(spacing: size.spacing) {
            Text(label)
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(AppTheme.aiGradient)
            SwiftUI.TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsedString(from: startedAt, to: context.date))
                    .font(.system(size: size.elapsedFontSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(AppTheme.Opacity.strong))
            }
        }
    }

    private static func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool

    @State private var phase: CGFloat = -1

    private static let duration: Double = 1.35

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.42), location: 0.48),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: geo.size.width * 0.45)
                        .rotationEffect(.degrees(18))
                        .offset(x: geo.size.width * phase)
                    }
                    .blendMode(.screen)
                    .mask(content)
                }
            }
            .onAppear {
                guard active else { return }
                phase = -1
                withAnimation(.linear(duration: Self.duration).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

private extension View {
    func shimmering(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
