import CoreGraphics
import CoreVideo
import Foundation

/// Holds the growing image. Used only on the stitching queue.
///
/// Each frame is cut into narrow vertical strips and every strip's rows are fingerprinted. The
/// scroll distance comes from the strips that moved, so a sidebar, a scrollbar or a hover highlight
/// in part of the area doesn't break the match. Columns are also voted moving or fixed, and the
/// saved image is cropped to the columns that scrolled.
final class Stitcher {
    struct Progress { var height: Int; var missed: Bool; var full: Bool }

    /// About 25,000 px tall at most (≈150 MB for a wide area); the capture finishes there.
    static let maxRows = 25_000
    static let strips = 16

    private let scrollbar: Int
    private var width = 0
    private var out: [UInt8] = []
    /// Per-strip fingerprints of every row in `out`, to recognize content that's already captured.
    private var outStrips: [Stitch.Rows] = []
    /// The last frame that was stitched in, as fingerprints and as pixels (for column votes).
    private var last: [Stitch.Rows] = []
    private var lastPixels: [UInt8] = []
    private var moved: [Int] = [], stayed: [Int] = [], conflicted: [Int] = []
    private var missedSince: Date?

    init(scrollbarPixels: Int) { scrollbar = scrollbarPixels }

    private var height: Int { outStrips.first?.count ?? 0 }

    func add(_ buffer: CVPixelBuffer) -> Progress {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Progress(height: height, missed: false, full: false) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), bpr = CVPixelBufferGetBytesPerRow(buffer)
        let frame = UnsafeRawBufferPointer(start: base, count: bpr * h)
        // The scrollbar's columns never decide anything: they're left out of the strips.
        let content = max(Self.strips, w - scrollbar)
        let strips = (0..<Self.strips).map { i in
            Stitch.rows(frame, height: h, bytesPerRow: bpr, columns: (content * i / Self.strips)..<(content * (i + 1) / Self.strips))
        }

        func copy(_ range: Range<Int>) {
            for y in range { out.append(contentsOf: UnsafeRawBufferPointer(start: base + y * bpr, count: w * 4)) }
            for i in strips.indices {
                outStrips[i].hashes += strips[i].hashes[range]
                outStrips[i].flat += strips[i].flat[range]
            }
        }
        func remember() {
            last = strips
            lastPixels.removeAll(keepingCapacity: true)
            for y in 0..<h { lastPixels.append(contentsOf: UnsafeRawBufferPointer(start: base + y * bpr, count: w * 4)) }
        }

        guard !last.isEmpty, width == w, last[0].count == h else {
            width = w
            out = []
            out.reserveCapacity(w * 4 * h * 4)
            outStrips = strips.map { _ in Stitch.Rows(hashes: [], flat: []) }
            moved = Array(repeating: 0, count: w)
            stayed = moved
            conflicted = moved
            copy(0..<h)
            remember()
            return Progress(height: h, missed: false, full: false)
        }

        let changed = strips.indices.filter { strips[$0].hashes != last[$0].hashes }
        guard !changed.isEmpty else { return progress(missed: false) } // nothing moved
        let match = Stitch.step(last, strips)
        if match?.scrolled == 0 { return progress(missed: false) } // only a sidebar or hover changed

        if let match {
            missedSince = nil
            // Rows identical in place across the width at the top: a sticky header, not evidence.
            var top = 0
            while top < h * 2 / 5, strips.indices.allSatisfy({ strips[$0].hashes[top] == last[$0].hashes[top] }) { top += 1 }
            let votes = lastPixels.withUnsafeBytes { previous in
                Stitch.columnVotes(prev: previous, prevBytesPerRow: w * 4, next: frame, nextBytesPerRow: bpr,
                                   width: w, height: h, scrolled: match.scrolled, top: top, footer: match.footer)
            }
            for x in 0..<w {
                switch votes[x] {
                case 1: moved[x] += 1
                case -1: stayed[x] += 1
                case 2: conflicted[x] += 1
                default: break
                }
            }
            let (drop, range) = Stitch.splice(height: h, match)
            out.removeLast(drop * w * 4)
            for i in outStrips.indices {
                outStrips[i].hashes.removeLast(drop)
                outStrips[i].flat.removeLast(drop)
            }
            copy(range)
            remember()
        } else if let detailed = changed.max(by: { strips[$0].flat.count { !$0 } < strips[$1].flat.count { !$0 } }),
                  Stitch.contains(outStrips[detailed], strips[detailed]) {
            missedSince = nil // scrolled back up over what's already captured: nothing lost
        } else {
            // Part of the page went by unseen. Keep the last good frame, so scrolling back a little
            // picks up again; say so only if it lasts.
            missedSince = missedSince ?? Date()
        }
        return progress(missed: missedSince.map { Date().timeIntervalSince($0) > 1 } ?? false)
    }

    private func progress(missed: Bool) -> Progress {
        Progress(height: height, missed: missed, full: height >= Self.maxRows)
    }

    func image() -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        // The stream delivers BGRA: 32-bit little-endian with alpha first.
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        // Keep only the columns that scrolled: sidebars and the scrollbar fall away.
        // Padding is the page's background color nearly all the way down; a sidebar isn't.
        let rowStep = max(1, height / 300)
        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            out.withUnsafeBytes { $0.load(fromByteOffset: (y * width + x) * 4, as: UInt32.self) }
        }
        var counts: [UInt32: Int] = [:]
        for x in stride(from: 0, to: width, by: max(1, width / 64)) where moved[x] > 0 {
            for y in stride(from: 0, to: height, by: rowStep) { counts[pixel(x, y), default: 0] += 1 }
        }
        let background = counts.max { $0.value < $1.value }?.key
        let isPadding = { (x: Int) -> Bool in
            guard let background else { return false }
            var hits = 0, total = 0
            for y in stride(from: 0, to: self.height, by: rowStep) { total += 1; if pixel(x, y) == background { hits += 1 } }
            return hits * 10 >= total * 9
        }
        guard let span = Stitch.span(moved: moved, stayed: stayed, conflicted: conflicted, scrollbar: scrollbar, isPadding: isPadding),
              span.count < width else { return image }
        return image?.cropping(to: CGRect(x: span.lowerBound, y: 0, width: span.count, height: height))
    }
}
