import Foundation

struct ImageGenerationSubmission {
    let genInput: GenerationInput
    let references: [MediaAsset]
    let name: String?
    let numImages: Int
    let folderId: String?
    let buildParams: ([String]) -> BackendGenerationParams

    @MainActor
    @discardableResult
    func submit(
        service: GenerationService,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        service.generate(
            genInput: genInput,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: references,
            name: name,
            numImages: numImages,
            folderId: folderId,
            buildParams: buildParams,
            fileExtension: "jpg",
            projectURL: projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    @MainActor
    static func make(
        genInput baseInput: GenerationInput,
        model: ImageModelConfig,
        references: [MediaAsset],
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil
    ) -> ImageGenerationSubmission {
        var genInput = baseInput
        genInput.imageURLAssetIds = references.isEmpty ? nil : references.map(\.id)
        return ImageGenerationSubmission(
            genInput: genInput,
            references: references,
            name: name,
            numImages: numImages,
            folderId: folderId,
            buildParams: { uploaded in
                Self.imageParams(
                    prompt: genInput.prompt,
                    aspectRatio: genInput.aspectRatio,
                    resolution: genInput.resolution,
                    quality: genInput.quality,
                    uploaded: uploaded,
                    numImages: numImages,
                    stylePreset: genInput.stylePreset
                )
            }
        )
    }

    /// Routes an image request to the correct Venice endpoint. `/image/generate`
    /// rejects reference images, so anything with references must go through
    /// `/image/edit` (one image) or `/image/multi-edit` (two or three). Only
    /// referenceless requests use `/image/generate`.
    static func imageParams(
        prompt: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        uploaded: [String],
        numImages: Int,
        stylePreset: String?
    ) -> BackendGenerationParams {
        if uploaded.count >= 2 {
            return .imageMultiEdit(ImageMultiEditParams(
                sourceURLs: Array(uploaded.prefix(3)),
                prompt: prompt,
                aspectRatio: aspectRatio.isEmpty ? nil : aspectRatio
            ))
        }
        if let base = uploaded.first {
            return .imageEdit(ImageEditParams(
                sourceURL: base,
                prompt: prompt,
                aspectRatio: aspectRatio.isEmpty ? nil : aspectRatio
            ))
        }
        return .image(ImageGenerationParams(
            prompt: prompt,
            aspectRatio: aspectRatio,
            resolution: resolution,
            quality: quality,
            imageURLs: uploaded,
            numImages: numImages,
            stylePreset: stylePreset
        ))
    }
}
