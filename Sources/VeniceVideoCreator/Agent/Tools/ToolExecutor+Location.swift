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

        var location = LocationSpec(
            name: name, description: description, visualPrompt: visualPrompt,
            spatialAnchors: spatialAnchors
        )

        var attachedRefs: [MediaAsset] = []
        for id in args.stringArray("referenceMediaRefs") {
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image (got \(a.type.rawValue)).")
            }
            attachedRefs.append(a)
        }

        let defaultCount = attachedRefs.isEmpty ? 2 : 0
        let count = min(4, max(0, args.int("count") ?? defaultCount))

        var generatedIds: [String] = []
        if count > 0 {
            guard AccountService.shared.hasVeniceKey else {
                throw ToolError("Generating references requires a Venice API key. Tell the user to add it in Settings, or pass referenceMediaRefs instead.")
            }
            guard let model = try resolveImageModelForLocation(args) else {
                throw ToolError("Image model catalog not loaded yet. Try again in a moment.")
            }
            let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
            let resolution = args.string("resolution") ?? Self.cheapestResolution(model)
            let quality = model.qualities?.last
            if let err = model.validate(aspectRatio: aspectRatio, resolution: resolution, quality: quality, imageRefCount: 0, numImages: 1) {
                throw ToolError(err)
            }
            let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: attachedRefs)
            let provided = args.stringArray("angles")
            let angles = provided.isEmpty ? Self.locationAngles : provided
            for i in 0..<count {
                let angle = angles[i % angles.count]
                var genInput = GenerationInput(
                    prompt: "\(visualPrompt), \(angle), \(Self.locationRefStyleSuffix)",
                    model: model.id, duration: 0,
                    aspectRatio: aspectRatio, resolution: resolution, quality: quality
                )
                genInput.hasFace = false
                let pid = ImageGenerationSubmission.make(
                    genInput: genInput, model: model, references: [],
                    name: "\(name) · ref \(i + 1)", folderId: folderId
                ).submit(service: editor.generationService, projectURL: editor.projectURL, editor: editor)
                generatedIds.append(pid)
            }
        }

        location.referenceImageAssetIds = attachedRefs.map(\.id) + generatedIds
        // Lock one canonical plate by default (see createCharacter); shots using
        // this location follow the lock automatically.
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
            body["hint"] = "Location references are generating; the first is locked as the canonical plate (the user can switch it later). Call wait_for_media with these asset ids, then inspect them. Attach the location to shots via locationIds."
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

    // MARK: - Helpers

    private func resolveImageModelForLocation(_ args: [String: Any]) throws -> ImageModelConfig? {
        if let id = args.string("model") {
            guard let model = ImageModelConfig.allModels.first(where: { $0.id == id }) else {
                throw ToolError("Unknown image model '\(id)'.")
            }
            guard ModelPreferences.shared.isEnabled(id) else {
                throw ToolError("Image model '\(id)' is turned off in Settings → Models.")
            }
            return model
        }
        return ImageModelConfig.allModels.first { ModelPreferences.shared.isEnabled($0.id) }
    }
}
