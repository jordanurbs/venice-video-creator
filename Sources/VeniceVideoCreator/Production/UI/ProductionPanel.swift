import SwiftUI

/// Left-dock tab that surfaces the shot plan and production run: shot list with storyboard
/// thumbnails, status badges, run controls, and per-shot approve/regenerate actions. Operates
/// on the same `ShotPlan` + `ProductionOrchestrator` the agent drives, so both stay in sync.
struct ProductionPanel: View {
    @Environment(EditorViewModel.self) private var editor

    private var plan: ShotPlan? { editor.shotPlan }
    private var orchestrator: ProductionOrchestrator { editor.productionOrchestrator }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            if let plan, !plan.shots.isEmpty {
                runBar(plan)
                Divider().overlay(AppTheme.Border.subtleColor)
                shotList(plan)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(plan?.title ?? "Production")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let plan {
                Text("\(plan.shots.count) shot\(plan.shots.count == 1 ? "" : "s")")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("No shot plan yet.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Brainstorm a video with the agent, then ask it to save a shot plan. Shots, storyboards, and generation progress appear here.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
    }

    // MARK: - Run bar

    private func runBar(_ plan: ShotPlan) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if orchestrator.isRunning {
                    Button { orchestrator.cancel() } label: { controlLabel("Stop", "stop.fill") }
                        .buttonStyle(.plain)
                    if orchestrator.isPaused {
                        Button { orchestrator.unpause() } label: { controlLabel("Resume", "play.fill") }
                            .buttonStyle(.plain)
                    } else {
                        Button { orchestrator.pause() } label: { controlLabel("Pause", "pause.fill") }
                            .buttonStyle(.plain)
                    }
                } else {
                    Button { orchestrator.produceShots(ids: []) } label: { controlLabel("Produce all", "play.fill") }
                        .buttonStyle(.plain)
                        .disabled(!canProduce(plan))
                }
                Spacer(minLength: 0)
                if orchestrator.runningUSD > 0 {
                    Text(String(format: "$%.2f", orchestrator.runningUSD))
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .help("Approximate spend this run")
                }
            }
            if orchestrator.isRunning {
                ProgressView(value: Double(orchestrator.completedCount), total: Double(max(1, orchestrator.totalCount)))
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Accent.primary)
                Text(orchestrator.progressText)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            if let err = orchestrator.lastError, !orchestrator.isRunning {
                Text(err)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private func canProduce(_ plan: ShotPlan) -> Bool {
        plan.shots.contains { $0.status != .placed }
    }

    private func controlLabel(_ text: String, _ icon: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: icon).font(.system(size: AppTheme.FontSize.xxs))
            Text(text).font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        }
        .foregroundStyle(AppTheme.Text.primaryColor)
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
    }

    // MARK: - Shot list

    private func shotList(_ plan: ShotPlan) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(Array(plan.shots.enumerated()), id: \.element.id) { index, shot in
                    ShotRow(
                        shot: shot,
                        index: index,
                        thumbnail: thumbnail(for: shot),
                        isCurrent: orchestrator.currentShotId == shot.id,
                        canRegenerate: !orchestrator.isRunning,
                        onApprove: { editor.setShotStatus(id: shot.id, .approved) },
                        onRegenerate: { editor.productionOrchestrator.produceShots(ids: [shot.id]) }
                    )
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thumbnail(for shot: Shot) -> NSImage? {
        let id = shot.videoAssetId ?? shot.storyboardAssetId
        guard let id, let asset = editor.mediaAssets.first(where: { $0.id == id }) else { return nil }
        return asset.thumbnail
    }
}

// MARK: - Shot row

private struct ShotRow: View {
    let shot: Shot
    let index: Int
    let thumbnail: NSImage?
    let isCurrent: Bool
    let canRegenerate: Bool
    let onApprove: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            thumb
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(shot.slug ?? "S\(index + 1)")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    statusBadge
                    Spacer(minLength: 0)
                    Text("\(Int(shot.durationSeconds))s")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                if !shot.summary.isEmpty {
                    Text(shot.summary)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(2)
                }
                actions
            }
        }
        .padding(AppTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(isCurrent ? Color.white.opacity(AppTheme.Opacity.subtle) : Color.clear)
        )
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs).fill(Color.black)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
    }

    private var statusBadge: some View {
        Text(shot.status.rawValue)
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(statusColor.opacity(AppTheme.Opacity.faint)))
    }

    private var statusColor: Color {
        switch shot.status {
        case .planned, .storyboarded: return AppTheme.Text.tertiaryColor
        case .generating, .qa: return AppTheme.Status.warningColor
        case .approved, .placed: return AppTheme.Status.successColor
        case .failed: return AppTheme.Status.errorColor
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if shot.status == .placed || shot.status == .qa {
                Button(action: onApprove) { rowAction("Approve", "checkmark") }
                    .buttonStyle(.plain)
            }
            if shot.videoAssetId != nil || shot.status == .failed {
                Button(action: onRegenerate) { rowAction("Regenerate", "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(!canRegenerate)
            }
        }
        .padding(.top, AppTheme.Spacing.xxs)
    }

    private func rowAction(_ text: String, _ icon: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: icon).font(.system(size: AppTheme.FontSize.xxs))
            Text(text).font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
    }
}
