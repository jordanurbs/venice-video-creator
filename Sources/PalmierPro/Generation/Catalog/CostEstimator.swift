import Foundation

enum CostEstimator {

    static func videoCost(
        model: VideoModelConfig,
        durationSeconds: Int,
        resolution: String?,
        generateAudio: Bool
    ) -> Int? {
        guard !model.creditsPerSecond.isEmpty, durationSeconds > 0 else { return nil }
        guard var rate = resolvedRate(model.creditsPerSecond, key: resolution) else { return nil }
        if !generateAudio, let discount = model.audioDiscount(for: resolution) {
            rate *= discount
        }
        return ceilCredits(rate * Double(durationSeconds))
    }

    static func imageCost(
        model: ImageModelConfig,
        resolution: String?,
        quality: String?,
        numImages: Int = 1
    ) -> Int? {
        guard !model.creditsPerImage.isEmpty else { return nil }
        let count = Double(max(1, numImages))
        // 2D matrix lookup first (e.g. GPT Image 2 varies on both axes).
        if let r = resolution, let q = quality, let price = model.creditsPerImage["\(r)|\(q)"] {
            return ceilCredits(price * count)
        }
        // Quality-only lookup when the model varies on quality but not resolution.
        if model.qualities?.isEmpty == false, let q = quality, let price = model.creditsPerImage[q] {
            return ceilCredits(price * count)
        }
        guard let rate = resolvedRate(model.creditsPerImage, key: resolution) else { return nil }
        return ceilCredits(rate * count)
    }

    static func audioCost(
        model: AudioModelConfig,
        prompt: String,
        durationSeconds: Int?
    ) -> Int? {
        switch model.pricing {
        case .perThousandChars(let rate):
            let chars = prompt.count
            guard chars > 0 else { return nil }
            return ceilCredits(rate * (Double(chars) / 1000.0))
        case .perSecond(let rate):
            guard let secs = durationSeconds, secs > 0 else { return nil }
            return ceilCredits(rate * Double(secs))
        case .flat(let price):
            return ceilCredits(price)
        case .unknown:
            return nil
        }
    }

    static func upscaleCost(model: UpscaleModelConfig, durationSeconds: Int) -> Int? {
        let d = max(1, durationSeconds)
        return ceilCredits(model.creditsPerSecond * Double(d))
    }

    /// Recompute cost from a stored `GenerationInput`. Used on rerun.
    @MainActor
    static func cost(for genInput: GenerationInput) -> Int? {
        switch ModelRegistry.byId[genInput.model] {
        case .video(let m):
            return videoCost(
                model: m,
                durationSeconds: genInput.duration,
                resolution: genInput.resolution,
                generateAudio: genInput.generateAudio ?? true
            )
        case .image(let m):
            return imageCost(
                model: m,
                resolution: genInput.resolution,
                quality: genInput.quality,
                numImages: genInput.numImages ?? 1
            )
        case .audio(let m):
            let duration = (m.durations?.isEmpty == false || m.inputs.contains(.video)) ? genInput.duration : nil
            return audioCost(model: m, prompt: genInput.prompt, durationSeconds: duration)
        case .upscale(let m):
            return upscaleCost(model: m, durationSeconds: genInput.duration)
        case .none:
            return nil
        }
    }

    /// Internal cost values are USD cents, and 1 credit = $0.01, so the cent value
    /// equals the credit count.
    static func format(_ credits: Int?) -> String {
        guard let credits, credits > 0 else { return "—" }
        return credits == 1 ? "1 credit" : "\(credits) credits"
    }

    /// Convert a USD amount (e.g. a Venice quote) into credits at 1 credit = $0.01.
    static func creditsFromUSD(_ usd: Double) -> Int {
        max(0, Int((usd * 100).rounded(.up)))
    }

    static func formatUSD(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD"))
    }

    private static func resolvedRate(_ dict: [String: Double], key: String?) -> Double? {
        if let key, let v = dict[key] { return v }
        return dict[""]
    }

    private static func ceilCredits(_ credits: Double) -> Int {
        guard credits > 0 else { return 0 }
        return Int(credits.rounded(.up))
    }
}
