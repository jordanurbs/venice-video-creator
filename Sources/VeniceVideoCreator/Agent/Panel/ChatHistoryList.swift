import SwiftUI

struct ChatHistoryList: View {
    let sessions: [ChatSession]
    let currentId: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    @State private var pendingDeletion: ChatSession?

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessions.isEmpty {
                Text("No conversations yet")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(AppTheme.Spacing.md)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions) { session in
                            row(session: session)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 280)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
        .alert(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { session in
            Button("Delete", role: .destructive) { onDelete(session.id) }
            Button("Cancel", role: .cancel) { }
        } message: { session in
            Text("“\(session.title)” and its messages are permanently deleted.")
        }
    }

    private func row(session: ChatSession) -> some View {
        let isCurrent = session.id == currentId
        return HStack(spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(session.title)
                        .font(.system(size: AppTheme.FontSize.xs, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                }
                Text(Self.formatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if !isCurrent {
                Button { pendingDeletion = session } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Delete from history")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, 6)
        .background(isCurrent ? AppTheme.Accent.primary.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(session.id) }
    }
}
