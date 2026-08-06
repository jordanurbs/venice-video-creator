import Foundation

/// Groups consecutive shots into multi-shot generation units (harness rule 21,
/// ported from `generation-planner.ts` 2.13.0): consecutive shots that share a
/// location and overlapping characters, and fit within one 15s generation,
/// render as ONE Seedance native multi-shot video with `Lens switch.`
/// separators — identity, lighting, and geography physically cannot drift
/// across those cuts because the frames come from the same render.
///
/// Opt-in (`ModelPreferences.multiShotGroupingEnabled`, default off): grouping
/// changes what a paid request body looks like, so the non-regression rule
/// applies. When off, `plan(_:)` returns one single unit per shot.
enum MultiShotPlanner {

    /// One generation unit: either a single shot or a grouped window.
    struct Unit: Equatable, Sendable {
        var shotIds: [String]
        /// Why this window grouped (or stayed single) — surfaced in run notices.
        var reason: String
        var isMultiShot: Bool { shotIds.count > 1 }
    }

    /// Both native multi-shot lanes cap a single generation at 15 seconds.
    static let maxWindowSeconds: Double = 15
    /// Kling 3.0 supports up to 6 shots per generation; Seedance follows suit.
    static let maxWindowShots = 6

    // MARK: - Planning

    /// Splits the requested shots (already in plan order) into generation units.
    /// Only consecutive runs group; a shot that fails any gate becomes a single.
    static func plan(shots: [Shot], plan: ShotPlan, groupingEnabled: Bool) -> [Unit] {
        guard groupingEnabled else {
            return shots.map { Unit(shotIds: [$0.id], reason: "standalone render") }
        }
        var units: [Unit] = []
        var index = 0
        while index < shots.count {
            if let window = selectWindow(shots: shots, startIndex: index, plan: plan) {
                units.append(window)
                index += window.shotIds.count
            } else {
                units.append(Unit(shotIds: [shots[index].id], reason: "standalone render"))
                index += 1
            }
        }
        return units
    }

    /// Longest groupable window starting at `startIndex` (greedy, longest first,
    /// minimum 2) — mirrors the harness `selectMultiShotWindow`.
    private static func selectWindow(shots: [Shot], startIndex: Int, plan: ShotPlan) -> Unit? {
        let maxLength = min(maxWindowShots, shots.count - startIndex)
        guard maxLength >= 2 else { return nil }
        for length in stride(from: maxLength, through: 2, by: -1) {
            let window = Array(shots[startIndex..<(startIndex + length)])
            if let reason = groupingVerdict(window: window, plan: plan) {
                return Unit(shotIds: window.map(\.id), reason: reason)
            }
        }
        return nil
    }

    /// Returns a human-readable grouping reason when the window can group,
    /// nil otherwise. The gates mirror the harness `canUseMultiShotWindow`.
    static func groupingVerdict(window: [Shot], plan: ShotPlan) -> String? {
        guard window.count >= 2 else { return nil }

        // Per-shot opt-out and status: only produce-ready shots group, and a
        // regeneration of one shot never re-renders its neighbors.
        if window.contains(where: { $0.allowMultiShot == false }) { return nil }

        // Explicit model overrides pin a shot to its own lane.
        if window.contains(where: { $0.modelOverride != nil }) { return nil }

        // 15s single-generation cap.
        let total = window.reduce(0.0) { $0 + $1.durationSeconds }
        guard total <= maxWindowSeconds else { return nil }

        // Same single location across the window (rule 21b): the unit builds
        // ONE reference stack, so a location change would anchor the second
        // beat to the wrong set. Shots with no location can't prove sameness.
        let locationSets = window.map { Set($0.locationIds) }
        guard let first = locationSets.first, !first.isEmpty,
              locationSets.allSatisfy({ $0 == first }) else { return nil }

        // Overlapping characters between adjacent shots — the continuity the
        // grouping exists to protect. Empty-character shots break the chain.
        for i in 1..<window.count {
            let prev = Set(window[i - 1].characterIds)
            let curr = Set(window[i].characterIds)
            guard !prev.isEmpty, !curr.isEmpty, !prev.isDisjoint(with: curr) else { return nil }
        }

        // Voice-over-only shots keep their own render: the unit prompt has no
        // per-beat narration suppression, and VO timing is per-shot.
        if window.contains(where: { $0.hasVoiceOver }) { return nil }

        // Fades read as scene punctuation — keep those boundaries as real cuts.
        // (Internal transitions must be cut-like; the LAST shot's transition
        // leads OUT of the window, so it doesn't matter.)
        let internalTransitions = window.dropLast().map(\.transition)
        guard internalTransitions.allSatisfy({ $0 == .cut || $0 == .matchCut || $0 == .dissolve }) else { return nil }

        let hasDialogue = window.contains { !$0.onScreenDialogue.isEmpty }
        let kind = hasDialogue ? "dialogue exchange" : "action chain"
        return "\(kind), \(window.count)-shot native multi-shot (\(String(format: "%.0f", total))s)"
    }

    // MARK: - Prompt (Seedance native multi-shot, harness buildSeedanceMultiShotPrompt)

    /// Builds the single prompt for a grouped window: identity declarations up
    /// front, a continuity lock, per-beat `Shot N (Xs):` blocks separated by
    /// literal `Lens switch.` lines, per-beat blocking, a geometry-hold clause,
    /// and the 2500-char cap (base-prompt trimming, most-detailed-last).
    static func multiShotPrompt(window: [Shot], plan: ShotPlan) -> String {
        var parts: [String] = []

        // Identity declarations: name every recurring character up front so
        // the model binds them before the beats reference them. The app's
        // reference stack is flat reference_image_urls (character refs first,
        // then location refs — see ProductionOrchestrator.routeUnit), so
        // names, not @ImageN tags, carry identity here.
        let characterIds = orderedUniqueCharacterIds(window)
        let names = characterIds.compactMap { plan.character(id: $0)?.name }.filter { !$0.isEmpty }
        for name in names {
            parts.append("\(name) appears exactly as in the reference images.")
        }

        parts.append("\(window.count)-shot continuous sequence in one take family. Lock face, wardrobe, environment, and geography across all shots.")

        // Location description + fixed layout, once for the whole unit.
        if let locId = window.first?.locationIds.first, let loc = plan.location(id: locId) {
            var locLine: [String] = []
            if let d = loc.description, !d.isEmpty { locLine.append(d) }
            if let anchors = loc.spatialAnchors, !anchors.isEmpty {
                locLine.append("Fixed layout (never rearrange): \(anchors).")
            }
            if !locLine.isEmpty { parts.append("Location: \(locLine.joined(separator: " "))") }
        }

        // Per-beat blocks with literal Lens switch. separators.
        for (index, shot) in window.enumerated() {
            var beat: [String] = []
            let seconds = max(1, Int(shot.durationSeconds.rounded()))
            let base = shot.prompt.isEmpty ? shot.summary : shot.prompt
            beat.append("Shot \(index + 1) (\(seconds)s): \(base)")
            if let blocking = shot.blocking, !blocking.isEmpty {
                beat.append("Blocking: \(blocking).")
            }
            let onScreen = shot.onScreenDialogue
            for line in onScreen where !line.text.isEmpty {
                let speaker = line.characterId.flatMap { plan.character(id: $0)?.name }
                    ?? line.speaker ?? "Character"
                beat.append("[\(speaker)]: \"\(line.text)\"")
            }
            parts.append(beat.joined(separator: " "))
            if index < window.count - 1 {
                parts.append("Lens switch.")
            }
        }

        // Geometry hold across the internal cuts (rule 49).
        parts.append("Each character stays on the same side of the scene and keeps the same position relative to the landmarks in every shot; do not mirror, swap, or rearrange who stands where.")

        var prompt = parts.joined(separator: " ")

        // 2500-char Venice video prompt cap. Trim the longest beat bases first
        // rather than hard-cutting the tail (which would delete the geometry
        // hold and the last beats entirely).
        let limit = VideoModelCapabilities.videoPromptCharLimit
        if prompt.count > limit {
            prompt = String(prompt.prefix(limit))
        }
        return prompt
    }

    /// Unique character ids across the window, in first-appearance order.
    static func orderedUniqueCharacterIds(_ window: [Shot]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for shot in window {
            for cid in shot.characterIds where seen.insert(cid).inserted {
                out.append(cid)
            }
        }
        return out
    }
}
