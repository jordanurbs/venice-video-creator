import AppKit
import SwiftUI

/// Lists the project's saved markdown documents (scripts, storyboards, shot lists)
/// and renders the selected one. Documents are authored by the agent via
/// `save_document` and persist with the project.
struct DocumentsTab: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var selectedId: String?

    private var documents: [ProjectDocument] { editor.documents }
    private var selected: ProjectDocument? {
        documents.first { $0.id == selectedId } ?? documents.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            if documents.isEmpty {
                empty
            } else {
                list
                Divider().overlay(AppTheme.Border.subtleColor)
                detail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Documents")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: 0)
            if !documents.isEmpty {
                Text("\(documents.count)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("No documents yet.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Ask the agent for a script, storyboard, or shot list and it will be saved here.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                ForEach(documents) { doc in
                    documentRow(doc)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
        .frame(maxHeight: 180)
    }

    private func documentRow(_ doc: ProjectDocument) -> some View {
        let isSelected = selected?.id == doc.id
        return Button {
            selectedId = doc.id
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(isSelected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(doc.name)
                        .font(.system(size: AppTheme.FontSize.sm, weight: isSelected ? AppTheme.FontWeight.medium : AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    Text(Self.relativeDate(doc.updatedAt))
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isSelected ? Color.white.opacity(AppTheme.Opacity.subtle) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy") { copy(doc) }
            if editor.documentFileURL(for: doc) != nil {
                Button("Reveal in Finder") { reveal(doc) }
                Button("Open in Default Editor") { open(doc) }
            }
            Divider()
            Button("Delete", role: .destructive) { editor.deleteDocument(id: doc.id) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(selected.name)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { copy(selected) } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .buttonStyle(.plain)
                    .help("Copy markdown")
                    if editor.documentFileURL(for: selected) != nil {
                        Button { reveal(selected) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal .md in Finder")
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)

                ScrollView {
                    MarkdownText(text: selected.content)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.bottom, AppTheme.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Actions

    private func copy(_ doc: ProjectDocument) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(doc.content, forType: .string)
    }

    private func reveal(_ doc: ProjectDocument) {
        guard let url = editor.documentFileURL(for: doc) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func open(_ doc: ProjectDocument) {
        guard let url = editor.documentFileURL(for: doc) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
