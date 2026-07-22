import Foundation

extension EditorViewModel {
    // MARK: - Reads

    var shotPlan: ShotPlan? { mediaManifest.shotPlan }

    func shot(id: String) -> Shot? { mediaManifest.shotPlan?.shot(id: id) }
    func character(id: String) -> CharacterSpec? { mediaManifest.shotPlan?.character(id: id) }

    // MARK: - Writes

    /// Replaces the whole plan (stamping `updatedAt`), registers undo, mirrors a markdown
    /// document into the Documents tab, and marks the project dirty.
    @discardableResult
    func saveShotPlan(_ plan: ShotPlan) -> ShotPlan {
        var updated = plan
        updated.updatedAt = Date()
        applyShotPlan(updated, actionName: "Edit Shot Plan")
        return updated
    }

    /// Mutates the current plan in place (creating an empty one if none exists) and persists.
    @discardableResult
    func mutateShotPlan(actionName: String, _ mutate: (inout ShotPlan) -> Void) -> ShotPlan {
        var plan = mediaManifest.shotPlan ?? ShotPlan()
        mutate(&plan)
        plan.updatedAt = Date()
        applyShotPlan(plan, actionName: actionName)
        return plan
    }

    func clearShotPlan() {
        guard mediaManifest.shotPlan != nil else { return }
        let previous = mediaManifest.shotPlan
        mediaManifest.shotPlan = nil
        undoManager?.registerUndo(withTarget: self) { vm in
            if let previous { vm.applyShotPlan(previous, actionName: "Restore Shot Plan") }
        }
        undoManager?.setActionName("Clear Shot Plan")
        onProjectContentChanged?()
    }

    // MARK: - Shot mutations

    /// Upserts a shot by id; appends when new. Returns the stored shot.
    @discardableResult
    func upsertShot(_ shot: Shot) -> Shot {
        mutateShotPlan(actionName: "Update Shot") { plan in
            if let idx = plan.shots.firstIndex(where: { $0.id == shot.id }) {
                plan.shots[idx] = shot
            } else {
                plan.shots.append(shot)
            }
        }
        return shot
    }

    func removeShot(id: String) {
        mutateShotPlan(actionName: "Remove Shot") { plan in
            plan.shots.removeAll { $0.id == id }
        }
    }

    /// Reorders shots to match `orderedIds`; ids not present are left in their relative order at the end.
    func reorderShots(orderedIds: [String]) {
        mutateShotPlan(actionName: "Reorder Shots") { plan in
            var byId = Dictionary(plan.shots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var reordered: [Shot] = []
            for id in orderedIds {
                if let shot = byId.removeValue(forKey: id) { reordered.append(shot) }
            }
            // Preserve any leftover shots in their original order.
            for shot in plan.shots where byId[shot.id] != nil {
                reordered.append(shot)
                byId[shot.id] = nil
            }
            plan.shots = reordered
        }
    }

    func setShotStatus(id: String, _ status: ShotStatus) {
        mutateShotPlan(actionName: "Set Shot Status") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == id }) else { return }
            plan.shots[idx].status = status
        }
    }

    // MARK: - Character mutations

    @discardableResult
    func upsertCharacter(_ character: CharacterSpec) -> CharacterSpec {
        mutateShotPlan(actionName: "Update Character") { plan in
            if let idx = plan.characters.firstIndex(where: { $0.id == character.id }) {
                plan.characters[idx] = character
            } else {
                plan.characters.append(character)
            }
        }
        return character
    }

    func removeCharacter(id: String) {
        mutateShotPlan(actionName: "Remove Character") { plan in
            plan.characters.removeAll { $0.id == id }
            for i in plan.shots.indices {
                plan.shots[i].characterIds.removeAll { $0 == id }
            }
        }
    }

    // MARK: - Internal apply + undo + mirror

    private func applyShotPlan(_ plan: ShotPlan, actionName: String) {
        let previous = mediaManifest.shotPlan
        mediaManifest.shotPlan = plan
        undoManager?.registerUndo(withTarget: self) { vm in
            if let previous {
                vm.applyShotPlan(previous, actionName: actionName)
            } else {
                vm.clearShotPlan()
            }
        }
        undoManager?.setActionName(actionName)
        // Mirror a human-readable version into the Documents library (upserted by name).
        saveDocument(name: Self.shotPlanDocumentName, content: plan.markdown())
        onProjectContentChanged?()
    }

    static let shotPlanDocumentName = "Shot Plan"
}

// MARK: - Markdown mirror

extension ShotPlan {
    /// Renders a human-readable markdown mirror shown in the Documents tab.
    func markdown() -> String {
        var out = "# \(title)\n\n"
        if let logline, !logline.isEmpty { out += "\(logline)\n\n" }
        out += "- **Format:** \(aspectRatio) · \(resolution)\n"
        if let defaultModel, !defaultModel.isEmpty { out += "- **Default model:** \(defaultModel)\n" }
        out += "- **Shots:** \(shots.count) · **Planned runtime:** \(Self.formatSeconds(totalPlannedSeconds))\n\n"

        if !characters.isEmpty {
            out += "## Characters\n\n"
            for c in characters {
                out += "- **\(c.name.isEmpty ? "(unnamed)" : c.name)**"
                if let d = c.description, !d.isEmpty { out += " — \(d)" }
                if let v = c.lockedVoiceId, !v.isEmpty { out += " · voice: `\(v)`" }
                let refs = c.referenceImageAssetIds.count
                if refs > 0 { out += " · \(refs) ref image\(refs == 1 ? "" : "s")" }
                out += "\n"
            }
            out += "\n"
        }

        out += "## Shots\n\n"
        if shots.isEmpty {
            out += "_No shots yet._\n"
        }
        for (i, shot) in shots.enumerated() {
            let label = shot.slug ?? "Shot \(i + 1)"
            out += "### \(label) — \(shot.status.rawValue)\n\n"
            if !shot.summary.isEmpty { out += "\(shot.summary)\n\n" }
            out += "- **Duration:** \(Self.formatSeconds(shot.durationSeconds)) · **Motion:** \(shot.motionLevel.rawValue) · **Transition:** \(shot.transition.rawValue)\n"
            if let m = shot.modelOverride, !m.isEmpty { out += "- **Model:** \(m)\n" }
            if !shot.characterIds.isEmpty {
                let names = shot.characterIds.map { id in character(id: id)?.name ?? id }
                out += "- **Characters:** \(names.joined(separator: ", "))\n"
            }
            if !shot.prompt.isEmpty { out += "- **Prompt:** \(shot.prompt)\n" }
            for line in shot.dialogue {
                let who = line.characterId.flatMap { character(id: $0)?.name } ?? line.speaker ?? "Speaker"
                let tag = line.voiceOver ? " (V.O.)" : ""
                out += "  - **\(who)\(tag):** \(line.text)\n"
            }
            if shot.takes.count > 1 { out += "- **Takes:** \(shot.takes.count)\n" }
            if let qa = shot.qaSummary, !qa.isEmpty { out += "- **QA:** \(qa)\n" }
            if let fail = shot.failureReason, !fail.isEmpty { out += "- **Failure:** \(fail)\n" }
            out += "\n"
        }
        return out
    }

    private static func formatSeconds(_ s: Double) -> String {
        if s <= 0 { return "0s" }
        if s < 60 { return s == s.rounded() ? "\(Int(s))s" : String(format: "%.1fs", s) }
        let m = Int(s) / 60
        let rem = Int(s) % 60
        return rem == 0 ? "\(m)m" : "\(m)m \(rem)s"
    }
}
