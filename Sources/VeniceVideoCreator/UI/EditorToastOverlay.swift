import SwiftUI

/// Window-level transient notice. The single surface for editor results and
/// warnings, so no flow can report into a hidden panel.
struct EditorToastOverlay: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        VStack {
            Spacer()
            if let toast = editor.editorToast {
                banner(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: AppTheme.Anim.transition), value: editor.editorToast)
        .allowsHitTesting(editor.editorToast != nil)
    }

    private func banner(_ toast: MediaPanelToast) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(toast.kind == .success ? AppTheme.Status.successColor : AppTheme.Accent.timecodeColor)
            Text(toast.message)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.prominentColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.bottom, AppTheme.Spacing.lgXl)
        .onTapGesture { editor.dismissMediaPanelToast() }
        .task(id: toast) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            editor.dismissMediaPanelToast()
        }
    }
}
