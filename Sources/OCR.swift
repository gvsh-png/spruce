import AppKit
import ImageIO
import Vision

/// Step 2 of the pipeline: read text from the screenshot on-device with Vision.
/// Nothing here touches the network.
enum OCR {
    /// Every recognized line with its confidence and position, what any QR codes say, and where the
    /// sensitive words are (`TextRules.sensitiveRanges`, in Vision's normalized coordinates) for Redact.
    /// Slow (100–800 ms), so call it off the main thread. Throws when the file is not a readable image.
    static func read(_ url: URL) throws -> (lines: [OCRLine], codes: [String], sensitive: [CGRect]) {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let qr = VNDetectBarcodesRequest()
        qr.symbologies = [.qr]
        try VNImageRequestHandler(url: url).perform([text, qr]) // one decode for both
        var lines: [OCRLine] = []
        var sensitive: [CGRect] = []
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(OCRLine(text: candidate.string, confidence: candidate.confidence, box: observation.boundingBox))
            // Just the matching characters, not the whole line; the whole line if Vision has no box for them.
            for range in TextRules.sensitiveRanges(candidate.string) {
                sensitive.append((try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox)
            }
        }
        var codes: [String] = []
        for payload in (qr.results ?? []).compactMap(\.payloadStringValue) where !codes.contains(payload) {
            codes.append(payload)
        }
        return (lines, codes, sensitive)
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
