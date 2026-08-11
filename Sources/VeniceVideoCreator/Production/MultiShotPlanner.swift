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
    static func multiShotPrompt(window: [Shot], plan: ShotPlan, slotPlan: ReferenceSlots.Plan? = nil) -> String {
        func tagged(_ text: String) -> String { slotPlan?.substitutingNames(in: text) ?? text }

        // Identity declarations. On an @Image-tag model the slot plan binds each
        // reference to a slot ("@Image1 is Bob", "@Image5 is the location …") and
        // names are substituted with @ImageN throughout; otherwise the app's flat
        // reference stack carries identity by NAME in prose.
        let characterIds = orderedUniqueCharacterIds(window)
        let names = characterIds.compactMap { plan.character(id: $0)?.name }.filter { !$0.isEmpty }
        let identityLines: [String]
        if let slotPlan, !slotPlan.isEmpty {
            identityLines = slotPlan.identityDeclarations + slotPlan.roleClauseLines
        } else {
            identityLines = names.map { "\($0) appears exactly as in the reference images." }
        }

        let continuity = "\(window.count)-shot continuous sequence in one take family. Lock face, wardrobe, environment, and geography across all shots."

        // Location description + fixed layout, once for the whole unit.
        var locationLine: String?
        if let locId = window.first?.locationIds.first, let loc = plan.location(id: locId) {
            var locParts: [String] = []
            if let d = loc.description, !d.isEmpty { locParts.append(d) }
            if let anchors = loc.spatialAnchors, !anchors.isEmpty {
                locParts.append("Fixed layout (never rearrange): \(anchors).")
            }
            if !locParts.isEmpty { locationLine = "Location: \(locParts.joined(separator: " "))" }
        }

        // Per-beat blocks: the `base` action is trimmable under the cap; the
        // seconds label, blocking, and dialogue lines are structural and kept.
        struct Beat {
            let index: Int
            let seconds: Int
            var base: String
            let blocking: String?
            let dialogue: [String]
        }
        var beats: [Beat] = window.enumerated().map { index, shot in
            var lines: [String] = []
            for line in shot.onScreenDialogue where !line.text.isEmpty {
                let speaker = line.characterId.flatMap { plan.character(id: $0)?.name }
                    ?? line.speaker ?? "Character"
                lines.append("[\(tagged(speaker))]: \"\(tagged(line.text))\"")
            }
            let rawBlocking = (shot.blocking?.isEmpty == false) ? shot.blocking : nil
            return Beat(
                index: index, seconds: max(1, Int(shot.durationSeconds.rounded())),
                base: tagged(shot.prompt.isEmpty ? shot.summary : shot.prompt),
                blocking: rawBlocking.map(tagged), dialogue: lines
            )
        }

        // Geometry hold across the internal cuts (rule 49).
        let geometryHold = "Each character stays on the same side of the scene and keeps the same position relative to the landmarks in every shot; do not mirror, swap, or rearrange who stands where."

        func assemble() -> String {
            var parts: [String] = []
            // Locked series style FIRST (harness rule 11) — one front-loaded
            // style anchor at the top of the multi-beat prompt.
            if let style = ShotPromptBuilder.stylePrefix(plan) { parts.append(style) }
            parts.append(contentsOf: identityLines)
            parts.append(continuity)
            if let locationLine { parts.append(locationLine) }
            for (i, beat) in beats.enumerated() {
                var beatParts = ["Shot \(beat.index + 1) (\(beat.seconds)s): \(beat.base)"]
                if let blocking = beat.blocking { beatParts.append("Blocking: \(blocking).") }
                beatParts.append(contentsOf: beat.dialogue)
                parts.append(beatParts.joined(separator: " "))
                if i < beats.count - 1 { parts.append("Lens switch.") }
            }
            parts.append(geometryHold)
            return parts.joined(separator: " ")
        }

        // 2500-char Venice video prompt cap. Shorten the LONGEST beat base first
        // (dropping trailing words) rather than hard-cutting the tail — which
        // would delete the geometry-hold clause and the last beats entirely.
        // Identity declarations, Lens switch. separators, blocking, and dialogue
        // all survive.
        let limit = VideoModelCapabilities.videoPromptCharLimit
        let minBaseChars = 24
        var prompt = assemble()
        var guardIterations = 0
        while prompt.count > limit, guardIterations < 500 {
            guardIterations += 1
            guard let longest = beats.indices
                .filter({ beats[$0].base.count > minBaseChars })
                .max(by: { beats[$0].base.count < beats[$1].base.count }) else { break }
            let overflow = prompt.count - limit
            beats[longest].base = trimTrailingWords(beats[longest].base, byAtLeast: overflow, floor: minBaseChars)
            prompt = assemble()
        }
        // Last resort if structural text alone still exceeds the cap.
        if prompt.count > limit { prompt = String(prompt.prefix(limit)) }
        return prompt
    }

    /// Shortens `text` by at least `byAtLeast` characters by dropping whole
    /// trailing words, never below `floor` characters, appending an ellipsis
    /// when anything was removed so the truncation reads as intentional.
    private static func trimTrailingWords(_ text: String, byAtLeast: Int, floor: Int) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else {
            // Single long token: hard-cut to floor as a fallback.
            return String(text.prefix(max(floor, text.count - byAtLeast)))
        }
        let target = max(floor, text.count - byAtLeast)
        var joined = words.joined(separator: " ")
        while joined.count + 1 > target, words.count > 1 {
            words.removeLast()
            joined = words.joined(separator: " ")
        }
        return joined + " …"
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
