import Foundation

extension ToolExecutor {
    // MARK: - save_shot_plan

    /// Creates or replaces the whole shot plan. Runtime state (status, storyboard/video
    /// assets, take history, QA) is preserved for shots whose id matches an existing shot,
    /// so re-saving a plan never discards generated work. Characters are likewise kept
    /// unless the args explicitly pass a `characters` array — an omitted key must not
    /// wipe locked voices and reference images.
    func saveShotPlan(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        var plan = try Self.decode(args, as: ShotPlan.self, path: "save_shot_plan")
        try Self.requireUniqueShotIds(plan.shots, path: "save_shot_plan")
        plan.shots = try plan.shots.map { try Self.validated($0, index: nil) }
        plan.shots = Self.mergeRuntimeState(newShots: plan.shots, existing: editor.shotPlan?.shots ?? [])
        if args["characters"] == nil, let existing = editor.shotPlan?.characters {
            plan.characters = existing
        }
        if args["locations"] == nil, let existing = editor.shotPlan?.locations {
            plan.locations = existing
        }
        let saved = editor.saveShotPlan(plan)
        return .ok(Self.jsonString(Self.summary(of: saved)) ?? "{}")
    }

    // MARK: - get_shot_plan

    func getShotPlan(_ editor: EditorViewModel) throws -> ToolResult {
        guard let plan = editor.shotPlan else {
            return .ok(#"{"shotPlan": null, "hint": "No shot plan yet. Use save_shot_plan to create one."}"#)
        }
        guard let obj = Self.encodeAsJSONObject(plan) else {
            throw ToolError("Failed to encode shot plan")
        }
        return .ok(Self.jsonString(obj) ?? "{}")
    }

    // MARK: - update_shots

    /// Surgical edits to the shot list: update / insert / remove / reorder. Takes an
    /// `operations` array applied in order. Planning-only; does not generate anything.
    func updateShots(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard editor.shotPlan != nil else {
            throw ToolError("No shot plan yet. Call save_shot_plan first.")
        }
        guard let ops = args["operations"] as? [[String: Any]], !ops.isEmpty else {
            throw ToolError("Provide a non-empty 'operations' array.")
        }

        let updated = try editor.mutateShotPlanThrowing(actionName: "Update Shots") { plan in
            for (i, op) in ops.enumerated() {
                try Self.apply(op, to: &plan, path: "operations[\(i)]")
            }
        }
        return .ok(Self.jsonString(Self.summary(of: updated)) ?? "{}")
    }

    // MARK: - Operation application

    private static func apply(_ op: [String: Any], to plan: inout ShotPlan, path: String) throws {
        guard let action = op.string("action") else {
            throw ToolError("\(path): missing 'action' (update | insert | remove | reorder).")
        }
        switch action {
        case "update":
            let id = try op.requireString("id")
            guard let idx = plan.shots.firstIndex(where: { $0.id == id }) else {
                throw ToolError("\(path): shot not found: \(id)")
            }
            try patch(&plan.shots[idx], from: op, path: path)
            plan.shots[idx] = try validated(plan.shots[idx], index: idx)

        case "insert":
            guard let shotObj = op["shot"] as? [String: Any] else {
                throw ToolError("\(path): 'insert' requires a 'shot' object.")
            }
            var shot = try decode(shotObj, as: Shot.self, path: "\(path).shot")
            shot = try validated(shot, index: nil)
            guard !plan.shots.contains(where: { $0.id == shot.id }) else {
                throw ToolError("\(path): a shot with id '\(shot.id)' already exists. Omit 'id' to insert a new shot.")
            }
            let insertIdx: Int
            if let afterId = op.string("afterId") {
                guard let after = plan.shots.firstIndex(where: { $0.id == afterId }) else {
                    throw ToolError("\(path): afterId not found: \(afterId)")
                }
                insertIdx = after + 1
            } else if let at = op.int("atIndex") {
                insertIdx = max(0, min(plan.shots.count, at))
            } else {
                insertIdx = plan.shots.count
            }
            plan.shots.insert(shot, at: insertIdx)

        case "remove":
            let id = try op.requireString("id")
            guard plan.shots.contains(where: { $0.id == id }) else {
                throw ToolError("\(path): shot not found: \(id)")
            }
            plan.shots.removeAll { $0.id == id }

        case "reorder":
            let ids = op.stringArray("orderedIds")
            guard !ids.isEmpty else { throw ToolError("\(path): 'reorder' requires 'orderedIds'.") }
            var byId = Dictionary(plan.shots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var reordered: [Shot] = []
            for id in ids {
                if let shot = byId.removeValue(forKey: id) { reordered.append(shot) }
            }
            for shot in plan.shots where byId[shot.id] != nil {
                reordered.append(shot); byId[shot.id] = nil
            }
            plan.shots = reordered

        default:
            throw ToolError("\(path): unknown action '\(action)'. Use update | insert | remove | reorder.")
        }
    }

    /// Applies only the fields present in `op` onto an existing shot (leaving others intact).
    private static func patch(_ shot: inout Shot, from op: [String: Any], path: String) throws {
        if let v = op.string("slug") { shot.slug = v }
        if let v = op.string("summary") { shot.summary = v }
        if let v = op.string("prompt") { shot.prompt = v }
        if let v = op.double("durationSeconds") { shot.durationSeconds = max(0.1, v) }
        if let v = op.string("motionLevel") { shot.motionLevel = try parseEnum(v, ShotMotionLevel.self, field: "\(path).motionLevel") }
        if let v = op.string("transition") { shot.transition = try parseEnum(v, ShotTransition.self, field: "\(path).transition") }
        if op["modelOverride"] != nil { shot.modelOverride = op.string("modelOverride") }
        if op["characterIds"] != nil { shot.characterIds = op.stringArray("characterIds") }
        if op["locationIds"] != nil { shot.locationIds = op.stringArray("locationIds") }
        if op["blocking"] != nil { shot.blocking = op.string("blocking") }
        if let v = op.string("nativeAudio") { shot.nativeAudio = try parseEnum(v, ShotNativeAudio.self, field: "\(path).nativeAudio") }
        if let v = op.string("audioContent") { shot.audioContent = try parseEnum(v, ShotAudioContent.self, field: "\(path).audioContent") }
        if op["audioReferenceAssetId"] != nil { shot.audioReferenceAssetId = op.string("audioReferenceAssetId") }
        if let v = op.bool("attachCastVoiceReference") { shot.attachCastVoiceReference = v }
        if let v = op.string("status") { shot.status = try parseEnum(v, ShotStatus.self, field: "\(path).status") }
        if let dlg = op["dialogue"] {
            shot.dialogue = try parseDialogue(dlg, path: "\(path).dialogue")
        }
    }

    private static func parseDialogue(_ any: Any, path: String) throws -> [ShotDialogue] {
        guard let arr = any as? [[String: Any]] else {
            throw ToolError("\(path): expected an array of dialogue objects.")
        }
        return try arr.map { try decode($0, as: ShotDialogue.self, path: path) }
    }

    private static func parseEnum<T: RawRepresentable & CaseIterable>(_ raw: String, _ type: T.Type, field: String) throws -> T where T.RawValue == String {
        guard let v = T(rawValue: raw) else {
            let allowed = T.allCases.map { String(describing: $0.rawValue) }.joined(separator: ", ")
            throw ToolError("\(field): invalid '\(raw)'. Allowed: \(allowed).")
        }
        return v
    }

    // MARK: - Validation & merge

    private static func validated(_ shot: Shot, index: Int?) throws -> Shot {
        var s = shot
        if s.durationSeconds <= 0 { s.durationSeconds = 5 }
        let cap = maxGenerableShotSeconds()
        if s.durationSeconds > cap {
            let label = s.slug ?? s.id
            throw ToolError(
                "Shot \(label): \(Int(s.durationSeconds))s exceeds the longest generable clip (\(Int(cap))s). "
                + "No video model generates more than \(Int(cap))s — split it into consecutive shots of ≤\(Int(cap))s "
                + "covering the same beat, with transition 'matchCut' (or 'dissolve') on all but the last part so "
                + "production chains each part from the previous part's last frame."
            )
        }
        return s
    }

    /// Longest duration any enabled video model can generate (fallback 15s).
    static func maxGenerableShotSeconds() -> Double {
        let maxDuration = VideoModelConfig.allModels
            .filter { ModelPreferences.shared.isEnabled($0.id) }
            .flatMap(\.durations)
            .max()
        return Double(maxDuration ?? 15)
    }

    /// Duplicate shot ids would silently merge state (and used to trap in
    /// `Dictionary(uniqueKeysWithValues:)`), so reject them up front with a clear error.
    private static func requireUniqueShotIds(_ shots: [Shot], path: String) throws {
        var seen: Set<String> = []
        for shot in shots where !seen.insert(shot.id).inserted {
            throw ToolError("\(path): duplicate shot id '\(shot.id)'. Each shot needs a unique id (or omit 'id' for new shots).")
        }
    }

    /// Carries production state (status, assets, takes, QA) from `existing` shots onto
    /// re-saved shots with the same id; new ids keep their planned defaults.
    private static func mergeRuntimeState(newShots: [Shot], existing: [Shot]) -> [Shot] {
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return newShots.map { incoming in
            guard let old = byId[incoming.id] else { return incoming }
            var merged = incoming
            merged.status = old.status
            merged.storyboardAssetId = old.storyboardAssetId
            merged.videoAssetId = old.videoAssetId
            merged.takes = old.takes
            merged.qaSummary = old.qaSummary
            merged.failureReason = old.failureReason
            return merged
        }
    }

    // MARK: - Response summary

    private static func summary(of plan: ShotPlan) -> [String: Any] {
        [
            "title": plan.title,
            "aspectRatio": plan.aspectRatio,
            "resolution": plan.resolution,
            "shotCount": plan.shots.count,
            "characterCount": plan.characters.count,
            "plannedSeconds": plan.totalPlannedSeconds,
            "shots": plan.shots.enumerated().map { i, s -> [String: Any] in
                var row: [String: Any] = [
                    "id": s.id,
                    "index": i,
                    "slug": s.slug ?? "S\(i + 1)",
                    "status": s.status.rawValue,
                    "durationSeconds": s.durationSeconds,
                ]
                if !s.summary.isEmpty { row["summary"] = s.summary }
                return row
            },
        ]
    }
}

extension EditorViewModel {
    /// Throwing variant of `mutateShotPlan` so a failed tool operation leaves the plan
    /// untouched: `mutate` runs on a copy and only persists when it succeeds.
    @discardableResult
    func mutateShotPlanThrowing(actionName: String, _ mutate: (inout ShotPlan) throws -> Void) throws -> ShotPlan {
        var plan = mediaManifest.shotPlan ?? ShotPlan()
        try mutate(&plan)
        return mutateShotPlan(actionName: actionName) { $0 = plan }
    }
}
