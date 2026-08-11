import Foundation

extension ToolExecutor {
    // MARK: - create_location

    /// Creates a recurring location and (by default) generates reference plates
    /// for it. Mirrors createCharacter minus voice/face concerns.
    func createLocation(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let name = try args.requireString("name")
        let description = args.string("description")
        let visualPrompt = args.string("prompt") ?? description ?? name
        let spatialAnchors = args.string("spatialAnchors")
        let lightingNotes = args.string("lightingNotes")

        var location = LocationSpec(
            name: name, description: description, visualPrompt: visualPrompt,
            spatialAnchors: spatialAnchors, lightingNotes: lightingNotes
        )

        var attachedRefs: [MediaAsset] = []
        for id in args.stringArray("referenceMediaRefs") {
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image (got \(a.type.rawValue)).")
            }
            attachedRefs.append(a)
        }

        // Harness parity: locations default to the full 3-angle ladder
        // (wide/medium/detail) — one angle per ref, all depicting ONE space.
        let defaultCount = attachedRefs.isEmpty ? Self.locationAngles.count : 0
        let count = min(4, max(0, args.int("count") ?? defaultCount))

        var generatedIds: [String] = []
        if count > 0 {
            guard AccountService.shared.hasVeniceKey else {
                throw ToolError("Generating references requires a Venice API key. Tell the user to add it in Settings, or pass referenceMediaRefs instead.")
            }
            guard let model = try resolveImageModelForLocation(args, editor: editor) else {
                throw ToolError("Image model catalog not loaded yet. Try again in a moment.")
            }
            let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
            // Location plates are tier-2 references — full quality/resolution
            // (harness quality floor), not the cheapest tier.
            let resolution = args.string("resolution") ?? Self.referenceResolution(model)
            let quality = args.string("quality") ?? Self.referenceQuality(model)
            if let err = model.validate(aspectRatio: aspectRatio, resolution: resolution, quality: quality, imageRefCount: 0, numImages: 1) {
                throw ToolError(err)
            }
            let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: attachedRefs)
            let provided = args.stringArray("angles")
            let angles = provided.isEmpty ? Self.locationAngles : provided
            // Bake locked geography into EVERY angle (harness rule 49) so the
            // ladder depicts one coherent space the video model can navigate.
            let anchorsClause = spatialAnchors.map { ", fixed layout (never rearrange): \($0)" } ?? ""
            // Front-load the plan's locked series style so plates match the look.
            let styleLead = ShotPromptBuilder.stylePrefix(editor.shotPlan).map { "\($0). " } ?? ""
            for i in 0..<count {
                let angle = angles[i % angles.count]
                var genInput = GenerationInput(
                    prompt: "\(styleLead)\(visualPrompt), \(angle)\(anchorsClause), \(Self.locationRefStyleSuffix)",
                    model: model.id, duration: 0,
                    aspectRatio: aspectRatio, resolution: resolution, quality: quality
                )
                genInput.hasFace = false
                Self.applyReferenceSeed(&genInput, model: model, plan: editor.shotPlan)
                let pid = ImageGenerationSubmission.make(
                    genInput: genInput, model: model, references: [],
                    name: "\(name) · ref \(i + 1)", folderId: folderId
                ).submit(service: editor.generationService, projectURL: editor.projectURL, editor: editor)
                generatedIds.append(pid)
            }
        }

        location.referenceImageAssetIds = attachedRefs.map(\.id) + generatedIds
        // Lock the wide angle as primary by default. Location locks PRIORITIZE
        // (the other angles still ride along) — see activeReferenceAssetIds.
        if location.lockedReferenceAssetId == nil, let first = location.referenceImageAssetIds.first {
            location.lockedReferenceAssetId = first
        }
        editor.upsertLocation(location)
        if !location.referenceImageAssetIds.isEmpty {
            editor.mediaPanelVisible = true
            editor.showMediaPanelLocationsTab()
        }

        var body: [String: Any] = [
            "id": location.id,
            "name": location.name,
            "referenceImageAssetIds": location.referenceImageAssetIds,
        ]
        if let locked = location.lockedReferenceAssetId {
            body["lockedReferenceAssetId"] = locked
        }
        if !generatedIds.isEmpty {
            body["generatingAssetIds"] = generatedIds
            body["hint"] = "Location angle ladder is generating (wide/medium/detail of ONE space). The wide angle is locked as primary; all angles ride shot generation together for environment coverage. Call wait_for_media with these asset ids, then inspect them. Attach the location to shots via locationIds."
        }
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - update_location

    func updateLocation(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let locationId = try args.requireString("locationId")
        guard var location = editor.location(id: locationId) else {
            throw ToolError("Location not found: \(locationId). Call get_shot_plan to list locations.")
        }

        if let name = args.string("name") { location.name = name }
        if let description = args.string("description") { location.description = description }
        if let prompt = args.string("prompt") { location.visualPrompt = prompt }
        if args.keys.contains("spatialAnchors") { location.spatialAnchors = args.string("spatialAnchors") }
        if args.keys.contains("lightingNotes") { location.lightingNotes = args.string("lightingNotes") }

        func validatedImageIds(_ key: String) throws -> [String]? {
            guard args[key] != nil else { return nil }
            let ids = args.stringArray(key)
            for id in ids {
                let a = try asset(id, editor: editor, label: "Reference image")
                guard a.type == .image else {
                    throw ToolError("\(key) entry '\(id)' must be an image (got \(a.type.rawValue)).")
                }
            }
            return ids
        }
        var referencesChanged = false
        if let replace = try validatedImageIds("referenceMediaRefs") {
            location.referenceImageAssetIds = replace
            referencesChanged = true
        }
        if let add = try validatedImageIds("addReferenceMediaRefs") {
            location.referenceImageAssetIds += add.filter { !location.referenceImageAssetIds.contains($0) }
            referencesChanged = !add.isEmpty || referencesChanged
        }
        // Detach without deleting: the assets stay in the media library.
        if args["removeReferenceMediaRefs"] != nil {
            let remove = Set(args.stringArray("removeReferenceMediaRefs"))
            let before = location.referenceImageAssetIds.count
            location.referenceImageAssetIds.removeAll { remove.contains($0) }
            referencesChanged = location.referenceImageAssetIds.count != before || referencesChanged
        }

        if args.keys.contains("lockedReferenceMediaRef") {
            if let locked = args.string("lockedReferenceMediaRef") {
                guard location.referenceImageAssetIds.contains(locked) else {
                    throw ToolError("lockedReferenceMediaRef '\(locked)' is not one of this location's references. Attach it first (addReferenceMediaRefs) or pick an attached id.")
                }
                location.lockedReferenceAssetId = locked
            } else {
                location.lockedReferenceAssetId = nil
            }
        }
        if let locked = location.lockedReferenceAssetId, !location.referenceImageAssetIds.contains(locked) {
            location.lockedReferenceAssetId = nil
        }

        editor.upsertLocation(location)
        if referencesChanged {
            editor.mediaPanelVisible = true
            editor.showMediaPanelLocationsTab()
        }
        var body: [String: Any] = [
            "id": location.id,
            "name": location.name,
            "referenceImageAssetIds": location.referenceImageAssetIds,
            "hint": "Location updated. References show in the Locations tab and are used for shot consistency.",
        ]
        if let locked = location.lockedReferenceAssetId {
            body["lockedReferenceAssetId"] = locked
        } else if location.referenceImageAssetIds.count > 1 {
            body["hint"] = "Location updated. Multiple references with no lock — if they show different environments, lock the best one (lockedReferenceMediaRef)."
        }
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - remove_location

    /// Deletes a location from the shot plan and detaches it from every shot.
    /// Reference plates stay in the media library. Undoable as one step.
    func removeLocation(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let locationId = try args.requireString("locationId")
        guard let location = editor.location(id: locationId) else {
            throw ToolError("Location not found: \(locationId). Call get_shot_plan to list locations.")
        }
        let affectedShots = (editor.shotPlan?.shots ?? [])
            .filter { $0.locationIds.contains(locationId) }
            .map { $0.slug ?? String($0.id.prefix(6)) }
        editor.removeLocation(id: locationId)
        var body: [String: Any] = [
            "removed": locationId,
            "name": location.name,
            "hint": "Location removed from the plan and detached from its shots. Its reference plates remain in the media library — call delete_media if they should be deleted too. The user can undo this.",
        ]
        if !affectedShots.isEmpty {
            body["detachedFromShots"] = affectedShots
        }
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - Helpers

    /// Same resolution order as characters: explicit arg > bakeoff-locked
    /// plan.referenceImageModel > first enabled.
    private func resolveImageModelForLocation(_ args: [String: Any], editor: EditorViewModel? = nil) throws -> ImageModelConfig? {
        try resolveImageModel(args, editor: editor)
    }
}
