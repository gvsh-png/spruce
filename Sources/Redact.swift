import CoreGraphics
import Foundation
import ImageIO

/// How Redact covers sensitive words.
enum RedactStyle: String, Codable, CaseIterable, Identifiable {
    case solid, pixelate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: "Solid"
        case .pixelate: "Pixelate"
        }
    }
}

/// Covers the sensitive words OCR found (emails, numbers, keys), using the boxes Vision already has.
/// Runs on-device; nothing here touches the network.
enum Redactor {
    /// The image at `url` with every box covered, encoded in the file's own format with its metadata
    /// (so a Retina screenshot still pastes at the right size). `boxes` use Vision's normalized
    /// coordinates, origin bottom-left. Nil when the file can't be read or encoded.
    static func render(_ url: URL, boxes: [CGRect], style: RedactStyle) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        // Keep Display P3 and other RGB spaces as they are; anything a bitmap context can't take becomes sRGB.
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? srgb
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)

        for box in boxes {
            // CGContext and Vision both put the origin at the bottom left, so no flip is needed here.
            let word = CGRect(x: box.minX * full.width, y: box.minY * full.height,
                              width: box.width * full.width, height: box.height * full.height)
            let pad = max(2, word.height * 0.12)
            let rect = word.insetBy(dx: -pad, dy: -pad).intersection(full).integral
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            switch style {
            case .solid:
                let radius = min(rect.height / 4, rect.width / 4, 6)
                context.setFillColor(CGColor(gray: 0.13, alpha: 1))
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            case .pixelate:
                pixelate(rect, of: image, into: context, space: space)
            }
        }

        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Big blocks (about the height of the text), so the words can't be read back.
    private static func pixelate(_ rect: CGRect, of image: CGImage, into context: CGContext, space: CGColorSpace) {
        // `cropping` counts from the top left.
        let flipped = CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)
        let block = max(8, rect.height * 0.6)
        let columns = max(1, Int((rect.width / block).rounded(.up))), rows = max(1, Int((rect.height / block).rounded(.up)))
        guard let crop = image.cropping(to: flipped),
              let small = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        small.interpolationQuality = .high // averages the pixels under each block
        small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let blocks = small.makeImage() else { return }
        context.saveGState()
        context.interpolationQuality = .none // hard edges between blocks
        context.draw(blocks, in: rect)
        context.restoreGState()
    }

    /// Copies every extended attribute (the screenshot flag, Spruce's own marks, Finder tags), so the
    /// redacted file is treated exactly like the original.
    static func copyAttributes(from source: URL, to destination: URL) {
        source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return }
                let size = listxattr(from, nil, 0, 0)
                guard size > 0 else { return }
                var names = [CChar](repeating: 0, count: size)
                guard listxattr(from, &names, size, 0) == size else { return }
                // The list is NUL-separated names.
                for raw in names.split(separator: 0) {
                    let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    // The saved OCR text still holds what was just covered; search reads the redacted image again later.
                    if name == XAttr.textKey { continue }
                    let length = getxattr(from, name, nil, 0, 0, 0)
                    guard length >= 0 else { continue }
                    var value = [UInt8](repeating: 0, count: max(length, 1))
                    guard getxattr(from, name, &value, length, 0, 0) == length else { continue }
                    _ = setxattr(to, name, value, length, 0, 0)
                }
            }
        }
    }
}
