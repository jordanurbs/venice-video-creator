import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Venice `/image/multi-edit` always returns a square (1024²) image regardless of the
/// requested aspect ratio. When the caller wanted a wide or tall result, center-crop the
/// square down to that ratio so compositions aren't left boxed. Cropping only — never
/// upscales — and returns the original bytes unchanged when no restoration is needed.
enum ImageAspectRestorer {
    static func restore(pngData: Data, toAspectRatio ratio: String?) -> Data {
        guard let target = parseRatio(ratio), target > 0 else { return pngData }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return pngData }

        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return pngData }

        let current = width / height
        if abs(current - target) < 0.01 { return pngData }

        let cropWidth: CGFloat, cropHeight: CGFloat
        if target > current {
            cropWidth = width
            cropHeight = (width / target).rounded()
        } else {
            cropHeight = height
            cropWidth = (height * target).rounded()
        }

        let x = ((width - cropWidth) / 2).rounded(.down)
        let y = ((height - cropHeight) / 2).rounded(.down)
        let rect = CGRect(x: x, y: y,
                          width: min(cropWidth, width - x),
                          height: min(cropHeight, height - y))

        guard let cropped = image.cropping(to: rect),
              let encoded = encodePNG(cropped) else { return pngData }
        return encoded
    }

    private static func parseRatio(_ ratio: String?) -> CGFloat? {
        guard let ratio, !ratio.isEmpty else { return nil }
        let parts = ratio.split(separator: ":")
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]), h > 0 else { return nil }
        return CGFloat(w / h)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
