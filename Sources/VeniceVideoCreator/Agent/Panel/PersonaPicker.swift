import AppKit
import SwiftUI

/// Searchable persona picker shown in the agent input footer.
///
/// Defaults to a curated, category-grouped set of useful personas; typing
/// searches the full Venice catalog and can pull any character by exact slug.
struct PersonaPicker: View {
    @Binding var selectedSlug: String?
    var catalog: CharacterCatalog

    @State private var searchText = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            searchBar
            Divider().overlay(AppTheme.Border.subtleColor)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    noPersonaRow
                    content
                }
            }
            .frame(maxHeight: 300)
            Divider().overlay(AppTheme.Border.subtleColor)
            createPersonaLink
        }
        .padding(AppTheme.Spacing.sm)
        .frame(width: 320)
        .onAppear { catalog.loadIfNeeded() }
        .onChange(of: searchText) { _, new in catalog.setSearch(new) }
        .onDisappear { catalog.setSearch("") }
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search personas or paste a character ID", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if isSearching {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            let loading = catalog.isSearching
            if loading && catalog.searchResults.isEmpty {
                stateText("Searching…")
            } else if catalog.searchResults.isEmpty {
                stateText("No characters found.")
            } else {
                sectionHeader("Results")
                ForEach(catalog.searchResults) { personaRow($0) }
            }
        } else {
            if catalog.isLoading && catalog.characters.isEmpty {
                stateText("Loading personas…")
            } else if catalog.characters.isEmpty {
                stateText("No personas available.")
            } else {
                ForEach(catalog.defaultGroups, id: \.category) { group in
                    sectionHeader(group.category)
                    ForEach(group.characters) { personaRow($0) }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.top, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.xxs)
    }

    private var noPersonaRow: some View {
        Button { selectedSlug = nil } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("No persona")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.sm)
                if selectedSlug == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func personaRow(_ character: VeniceCharacter) -> some View {
        let isSelected = selectedSlug == character.slug
        return HStack(spacing: AppTheme.Spacing.xs) {
            Button { selectedSlug = character.slug } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(character.name)
                            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .lineLimit(1)
                        if !character.description.isEmpty {
                            Text(character.description)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            Button { NSWorkspace.shared.open(character.veniceURL) } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("View this character on Venice")
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        .help(character.description.isEmpty ? character.name : character.description)
    }

    private var createPersonaLink: some View {
        Button { NSWorkspace.shared.open(CharacterCatalog.createCharacterURL) } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "plus.circle")
                    .font(.system(size: AppTheme.FontSize.sm))
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text("Create a new persona on Venice")
                            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    }
                    Text("Then paste its character ID into search above to use it here.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.Accent.primary)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Opens venice.ai/characters")
    }

    private func stateText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
    }
}
