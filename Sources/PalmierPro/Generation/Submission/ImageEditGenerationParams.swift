import Foundation

/// Parameters for Venice `/image/edit` — prompt-driven single-image transform.
struct ImageEditParams: Encodable, Sendable {
    /// Source image as a base64 string or `data:`/`https:` URL.
    let sourceURL: String
    let prompt: String
    let aspectRatio: String?

    enum CodingKeys: String, CodingKey { case kind, sourceURL, prompt, aspectRatio }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("imageEdit", forKey: .kind)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
    }
}

/// Parameters for Venice `/image/multi-edit` — compose 1–3 images with a prompt.
struct ImageMultiEditParams: Encodable, Sendable {
    /// Source images (base first), as base64 strings or `data:`/`https:` URLs.
    let sourceURLs: [String]
    let prompt: String
    /// Requested output aspect ratio. Venice returns a square image, so this is used
    /// to center-crop the result back to the intended shape (see `ImageAspectRestorer`).
    let aspectRatio: String?

    enum CodingKeys: String, CodingKey { case kind, sourceURLs, prompt, aspectRatio }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("imageMultiEdit", forKey: .kind)
        try c.encode(sourceURLs, forKey: .sourceURLs)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
    }
}

/// Parameters for Venice `/image/background-remove` — transparent cutout.
struct BackgroundRemoveParams: Encodable, Sendable {
    /// Source image as a base64 string or `data:`/`https:` URL.
    let sourceURL: String

    enum CodingKeys: String, CodingKey { case kind, sourceURL }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("backgroundRemove", forKey: .kind)
        try c.encode(sourceURL, forKey: .sourceURL)
    }
}

/// Sentinel model ids for endpoints that don't take a Venice catalog model.
enum VeniceBuiltInModel {
    static let backgroundRemove = "venice-background-remove"
    /// Default edit-capable model when none is chosen (Venice `/image/edit` default).
    static let defaultEdit = "qwen-edit"
}
