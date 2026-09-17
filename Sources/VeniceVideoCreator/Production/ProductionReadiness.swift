import CryptoKit
import Foundation

struct ProductionReadiness: Codable, Sendable {
    struct Issue: Codable, Sendable, Equatable {
        enum Severity: String, Codable, Sendable { case blocker, warning }
        var code: String
        var message: String
        var severity: Severity = .blocker
        var shotId: String?
        var clipId: String?
        var assetId: String?
    }
    var revision: String?
    var canExport: Bool
    var issues: [Issue]
    var checkedAt: Date

    var blockingMessage: String {
        var seen = Set<String>()
        return issues.filter { $0.severity == .blocker && seen.insert($0.message).inserted }.prefix(3).map(\.message).joined(separator: " ")
    }
}

struct VideoExportSnapshot {
    let timeline: Timeline
    let manifest: MediaManifest
    let resolver: MediaResolver
    let readiness: ProductionReadiness
    let revision: String
}

extension EditorViewModel {
    private struct ExportMediaFingerprint: Encodable {
        var id: String
        var path: String?
        var bytes: Int?
        var modified: Date?
        var status: String?
        var duration: Double?
    }

    private struct ExportRevision: Encodable {
        var timeline: Timeline
        var plan: ShotPlan?
        var media: [ExportMediaFingerprint]
        var video: [ProductionStatus.OperationSummary]
        var audio: [ProductionStatus.AudioSummary]
        var audioLayouts: [ProductionAudioCoordinator.LayoutState]
    }

    func videoExportRevision() throws -> String {
        let media = mediaManifest.entries.sorted { $0.id < $1.id }.map { entry in
            let url = mediaResolver.resolveURL(for: entry.id)
            let facts = try? url?.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let asset = mediaAssets.first { $0.id == entry.id }
            let duration = asset?.duration ?? entry.duration
            return ExportMediaFingerprint(id: entry.id, path: url?.path, bytes: facts?.fileSize,
                                          modified: facts?.contentModificationDate, status: asset?.generationStatus.serialized ?? entry.generationStatus,
                                          duration: duration.isFinite ? duration : nil)
        }
        let state = ExportRevision(timeline: timeline, plan: shotPlan, media: media,
            video: mediaManifest.productionOperations.map(ProductionStatus.OperationSummary.init),
            audio: mediaManifest.productionAudioOperations.map(ProductionStatus.AudioSummary.init),
            audioLayouts: mediaManifest.productionAudioOperations.map(ProductionAudioCoordinator.LayoutState.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(state)).map { String(format: "%02x", $0) }.joined()
    }

    func productionReadiness() async -> ProductionReadiness {
        var issues: [ProductionReadiness.Issue] = []
        let revision = try? videoExportRevision()
        if revision == nil { issues.append(.init(code: "invalidRevision", message: "Correct invalid project values before exporting.")) }
        let snapshot = timeline
        let plan = shotPlan
        guard snapshot.fps > 0, snapshot.fps <= Int(Int32.max), snapshot.width > 0, snapshot.height > 0 else {
            issues.append(.init(code: "invalidFormat", message: "Set valid timeline dimensions and frame rate."))
            return .init(revision: revision, canExport: false, issues: issues, checkedAt: Date())
        }
        let clips = snapshot.tracks.flatMap(\.clips)
        guard clips.allSatisfy({ $0.startFrame >= 0 && $0.durationFrames > 0 && $0.startFrame <= Int.max - $0.durationFrames }) else {
            issues.append(.init(code: "invalidTiming", message: "Correct invalid clip timing before exporting."))
            return .init(revision: revision, canExport: false, issues: issues, checkedAt: Date())
        }
        if clips.isEmpty { issues.append(.init(code: "emptyTimeline", message: "The timeline is empty.")) }
        if Set(clips.map(\.id)).count != clips.count || Set(mediaManifest.entries.map(\.id)).count != mediaManifest.entries.count {
            issues.append(.init(code: "duplicateIdentity", message: "Reconcile duplicate clip or media IDs before exporting."))
        }
        if productionOrchestrator.isRunning || productionAudioCoordinator.isFinishing || mediaAssets.contains(where: \.isGenerating) {
            issues.append(.init(code: "pendingProduction", message: "Wait for generation and finalization to finish before exporting."))
        }
        var checkedAssets = Set<String>()
        for clip in clips {
            guard clip.speed.isFinite, clip.speed > 0, clip.trimStartFrame >= 0, clip.trimEndFrame >= 0,
                  clip.volume.isFinite, clip.volume >= 0, clip.opacity.isFinite else {
                issues.append(.init(code: "invalidClip", message: "Correct invalid clip properties.", clipId: clip.id))
                continue
            }
            if clip.mediaType == .text { continue }
            guard let entry = mediaManifest.entries.first(where: { $0.id == clip.mediaRef }),
                  let url = mediaResolver.resolveURL(for: clip.mediaRef) else {
                issues.append(.init(code: "missingMedia", message: "Relink missing media before exporting.", clipId: clip.id, assetId: clip.mediaRef))
                continue
            }
            let asset = mediaAssets.first { $0.id == clip.mediaRef }
            if checkedAssets.insert(clip.mediaRef).inserted {
                if let asset, asset.generationStatus != .none {
                    issues.append(.init(code: "unfinishedMedia", message: "Finish or replace media whose generation has not completed.", assetId: asset.id))
                }
                if unprocessableMediaRefs.contains(clip.mediaRef) {
                    issues.append(.init(code: "unprocessableMedia", message: "Replace media that could not be decoded.", assetId: clip.mediaRef))
                }
                if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
                    issues.append(.init(code: "emptyMedia", message: "Replace the empty media file.", assetId: clip.mediaRef))
                }
            }
            if entry.type == .video || entry.type == .audio {
                let duration = asset?.duration ?? entry.duration
                let end = Double(clip.trimStartFrame) + Double(clip.durationFrames) * clip.speed
                if !duration.isFinite || duration <= 0 || !end.isFinite || end > duration * Double(snapshot.fps) + 1 {
                    issues.append(.init(code: "sourceCoverage", message: "The source does not cover the clip's edited range.", clipId: clip.id, assetId: clip.mediaRef))
                }
            }
        }
        let pictureEnd = snapshot.tracks.filter { $0.type == .video && !$0.hidden }.flatMap(\.clips).map(\.endFrame).max() ?? 0
        if pictureEnd > 0, snapshot.totalFrames > pictureEnd {
            issues.append(.init(code: "pictureTail", message: "Audio or hidden tracks extend beyond visible picture. Trim the tail or add intentional picture."))
        }
        if !mediaManifest.productionAudioOperations.isEmpty {
            do {
                if try productionAudioCoordinator.audioLayoutProposal().hasChanges {
                    issues.append(.init(code: "audioReconciliation", message: "Run Reconcile audio before exporting the current edit."))
                }
            } catch {
                issues.append(.init(code: "audioLayout", message: error.localizedDescription))
            }
        }
        var hashes: [String: String] = [:]
        for shot in plan?.shots ?? [] {
            guard let plan else { break }
            do {
                let panel = try requireApprovedStoryboard(for: shot, plan: plan)
                guard let placement = try productionPlacement(for: shot), let clip = try productionClip(for: shot) else {
                    issues.append(.init(code: "unplacedShot", message: "Place every planned shot before exporting.", shotId: shot.id))
                    continue
                }
                for id in placement.linkedAudioClipIds {
                    guard let audio = clipFor(id: id), audio.mediaRef == placement.assetId,
                          audio.linkGroupId != nil, audio.linkGroupId == clip.linkGroupId else {
                        issues.append(.init(code: "nativeBinding", message: "Restore or reconcile the shot's linked native audio.", shotId: shot.id, clipId: id))
                        continue
                    }
                    if audio.startFrame != clip.startFrame || audio.trimStartFrame != clip.trimStartFrame || audio.speed != clip.speed {
                        issues.append(.init(code: "nativeOffset", message: "Review the linked native-audio timing offset.", severity: .warning, shotId: shot.id, clipId: id))
                    }
                }
                if let id = shot.activeProductionOperationId {
                    guard let operation = productionOperation(id: id), operation.stage == .placed,
                          operation.failureReason == nil, let destination = operation.destinations.first(where: { $0.shotId == shot.id }),
                          operation.seed == plan.seed,
                          try StoryboardReviewGate.settingsDigest(shot: shot, plan: plan) == destination.settingsDigest,
                          destination.storyboardRevision == panel,
                          let evidence = operation.attempts.last?.finalization, evidence.validationFailure == nil,
                          evidence.assetId == placement.assetId,
                          evidence.placements[shot.id]?.destinationBinding == placement.destinationBinding else {
                        issues.append(.init(code: "staleTake", message: "Finalize a take for the current shot revision before exporting.", shotId: shot.id))
                        continue
                    }
                    let range = ShotSourceRange(startSeconds: Double(clip.trimStartFrame) / Double(snapshot.fps),
                        endSeconds: (Double(clip.trimStartFrame) + Double(clip.durationFrames) * clip.speed) / Double(snapshot.fps))
                    if operation.autoQA {
                        let reviewed = evidence.reviews.contains { review in
                            review.shotId == shot.id && review.passed
                                && (review.qaPassed != false || review.approvalReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                                && range.startSeconds + 1 / Double(snapshot.fps) >= review.sourceRange.startSeconds
                                && range.endSeconds <= review.sourceRange.endSeconds + 1 / Double(snapshot.fps)
                        }
                        if !reviewed { issues.append(.init(code: "unreviewedRange", message: "Review the shot's currently used source range.", shotId: shot.id)) }
                    } else {
                        issues.append(.init(code: "qaDisabled", message: "This take was produced with automatic QA disabled.", severity: .warning, shotId: shot.id))
                    }
                    if let asset = mediaAssets.first(where: { $0.id == evidence.assetId }) {
                        if hashes[asset.id] == nil { hashes[asset.id] = try await productionOrchestrator.outputDigest(asset) }
                        if hashes[asset.id] != evidence.contentDigest {
                            issues.append(.init(code: "changedVideo", message: "Video bytes changed after validation. Review the current take before exporting.", shotId: shot.id, assetId: asset.id))
                        }
                    } else { issues.append(.init(code: "missingTake", message: "Restore the shot's validated video asset.", shotId: shot.id)) }
                } else {
                    issues.append(.init(code: "legacyReview", message: "This placed shot has no revision-bound production review.", severity: .warning, shotId: shot.id))
                }
                for line in shot.dialogue where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if line.voiceOver {
                        let key = ProductionAudioOperation.Key(role: .dialogue, shotId: shot.id, lineId: line.id)
                        guard let audio = productionAudioCoordinator.latest(for: key), audio.stage == .placed,
                              let placed = audio.placedClip, let location = findClip(id: placed.id),
                              timeline.tracks[location.trackIndex].clips[location.clipIndex].mediaRef == placed.mediaRef else {
                            issues.append(.init(code: "missingVoiceOver", message: "Produce and place every planned voice-over line.", shotId: shot.id))
                            continue
                        }
                        let voice = timeline.tracks[location.trackIndex].clips[location.clipIndex]
                        let silentEnvelope = voice.volumeTrack.map { $0.isActive && $0.keyframes.allSatisfy { $0.value <= VolumeScale.floorDb } } ?? false
                        if timeline.tracks[location.trackIndex].muted || voice.volume == 0 || silentEnvelope {
                            issues.append(.init(code: "mutedVoiceOver", message: "A required voice-over line is muted.", shotId: shot.id, clipId: placed.id))
                        }
                    } else {
                        issues.append(.init(code: "nativeSpeechUnverified", message: "On-screen speech has not been transcript or lip-sync verified.", severity: .warning, shotId: shot.id))
                        if shot.nativeAudio == .mute {
                            issues.append(.init(code: "nativeSpeechMuted", message: "Native speech is explicitly muted in this edit.", severity: .warning, shotId: shot.id))
                        } else if placement.linkedAudioClipIds.isEmpty || mediaAssets.first(where: { $0.id == placement.assetId })?.hasAudio == false {
                            issues.append(.init(code: "missingNativeSpeech", message: "Restore native audio for the planned on-screen speech.", shotId: shot.id))
                        }
                    }
                }
            } catch {
                issues.append(.init(code: "shotReadiness", message: error.localizedDescription, shotId: shot.id))
            }
        }
        if Task.isCancelled { issues.append(.init(code: "cancelled", message: "Readiness check cancelled.")) }
        if revision != (try? videoExportRevision()) {
            issues.append(.init(code: "projectChanged", message: "The project changed during readiness checks. Check the current revision again."))
        }
        return .init(revision: revision, canExport: !issues.contains { $0.severity == .blocker }, issues: issues, checkedAt: Date())
    }

    func prepareVideoExport() async throws -> VideoExportSnapshot {
        let readiness = await productionReadiness()
        try Task.checkCancellation()
        guard readiness.canExport, let revision = readiness.revision else { throw ToolError(readiness.blockingMessage) }
        guard try videoExportRevision() == revision else { throw ToolError("The project changed after readiness checks. Check the current revision again.") }
        return VideoExportSnapshot(timeline: timeline, manifest: mediaManifest, resolver: mediaResolver.snapshot(), readiness: readiness, revision: revision)
    }
}
