import AppKit
import ImageIO
import Vision

/// Step 2 of the pipeline: read text from the screenshot on-device with Vision.
/// Nothing here touches the network.
enum OCR {
    /// Every recognized line with its confidence and position. Slow (100–800 ms), so call it off the main thread.
    /// Throws when the file is not a readable image.
    static func lines(in url: URL) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(url: url).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                OCRLine(text: $0.string, confidence: $0.confidence, box: observation.boundingBox)
            }
        }
    }

    /// A small JPEG, used only when the screenshot has almost no text and the provider may see images.
    static func thumbnail(of url: URL, maxPixel: Int = 512) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
