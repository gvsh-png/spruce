/// Scroll capture's stitching, kept free of AppKit so the self-check can test it.
///
/// Each frame is reduced to one fingerprint per pixel row. Two frames line up when the rows of the
/// new frame equal the rows of the previous one shifted up by `scrolled` rows. Rows that stay put
/// at the top or bottom (sticky headers, toolbars, footers) are left out of the comparison, and only
/// the rows that scrolled into view are added to the image.
enum Stitch {
    struct Rows: Equatable {
        var hashes: [UInt64]
        /// One color across the whole row: tells nothing about position, so it never decides a match.
        var flat: [Bool]
        var count: Int { hashes.count }
    }

    /// How a new frame relates to the previous one.
    struct Match: Equatable {
        /// Rows that scrolled up; that many new rows are visible at the bottom of the moving part.
        var scrolled: Int
        /// Rows at the bottom that didn't move (a footer or toolbar).
        var footer: Int
    }

    /// How to grow the image with a matched frame: drop the old footer rows from its end, then add
    /// these rows of the new frame (the newly visible content followed by the footer again).
    static func splice(height: Int, _ m: Match) -> (dropLast: Int, append: Range<Int>) {
        (m.footer, (height - m.footer - m.scrolled)..<height)
    }

    /// True when `next` shows content already in the image (`out`), e.g. after scrolling back up.
    /// Then nothing was missed; only a frame that fits nowhere means part of the page was skipped.
    static func contains(_ out: Rows, _ next: Rows) -> Bool {
        var index: [UInt64: [Int]] = [:]
        for (i, h) in out.hashes.enumerated() where !out.flat[i] { index[h, default: []].append(i) }
        // Anchor on a few distinctive rows from the middle of the frame (clear of fixed bars).
        let middle = Array(next.count / 4..<max(next.count / 4 + 1, next.count * 3 / 4))
        let anchors = middle.filter { !next.flat[$0] }.prefix(3)
        for a in anchors {
            for p in index[next.hashes[a]] ?? [] {
                let offset = p - a
                var informative = 0, agree = 0
                for j in middle where offset + j >= 0 && offset + j < out.count && !next.flat[j] {
                    informative += 1
                    if out.hashes[offset + j] == next.hashes[j] { agree += 1 }
                }
                if informative >= 8, Double(agree) >= 0.8 * Double(informative) { return true }
            }
        }
        return false
    }

    /// Fingerprints every row of a 32-bit pixel buffer, over `columns` only. Leaving out the right
    /// edge ignores the overlay scrollbar that flashes there while scrolling.
    static func rows(_ pixels: UnsafeRawBufferPointer, height: Int, bytesPerRow: Int, columns: Range<Int>) -> Rows {
        var hashes = [UInt64](repeating: 0, count: height)
        var flat = [Bool](repeating: true, count: height)
        guard !columns.isEmpty else { return Rows(hashes: hashes, flat: flat) }
        for y in 0..<height {
            let row = pixels.baseAddress!.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            let first = row[columns.lowerBound]
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var same = true
            for x in columns {
                let px = row[x]
                hash = (hash ^ UInt64(px)) &* 0x100_0000_01b3
                same = same && px == first
            }
            hashes[y] = hash
            flat[y] = same
        }
        return Rows(hashes: hashes, flat: flat)
    }

    /// Lines `next` up against `prev`. Returns nil when there's no trustworthy match (scrolled too
    /// far between frames, scrolled up, or only blank rows overlap); `scrolled == 0` means no change.
    static func match(_ prev: Rows, _ next: Rows) -> Match? {
        let h = prev.count
        guard h == next.count, h > 0 else { return nil }
        if prev.hashes == next.hashes { return Match(scrolled: 0, footer: 0) }

        // Rows identical in place at the top and bottom: fixed bars, not page content.
        let cap = h * 2 / 5
        var top = 0
        while top < cap, prev.hashes[top] == next.hashes[top] { top += 1 }
        var bottom = 0
        while bottom < cap, prev.hashes[h - 1 - bottom] == next.hashes[h - 1 - bottom] { bottom += 1 }

        let moving = h - top - bottom
        let minOverlap = max(24, moving / 6) // at least this many rows must be seen in both frames
        guard moving > minOverlap else { return nil }

        var best: (scrolled: Int, score: Double)?
        for d in 1...(moving - minOverlap) {
            let overlap = moving - d
            var informative = 0, agree = 0, misses = 0
            let allowed = overlap / 10 // a blinking caret or hover highlight may differ
            for i in 0..<overlap {
                let a = top + d + i, b = top + i
                if prev.flat[a] && next.flat[b] {
                    if prev.hashes[a] != next.hashes[b] { misses += 1 }
                    continue
                }
                informative += 1
                if prev.hashes[a] == next.hashes[b] { agree += 1 } else { misses += 1 }
                if misses > allowed { break }
            }
            guard misses <= allowed, informative >= 8 else { continue }
            let score = Double(agree) / Double(informative)
            if score >= 0.9, score > (best?.score ?? 0) {
                best = (d, score)
                if score == 1 { break } // smallest exact shift wins
            }
        }
        return best.map { Match(scrolled: $0.scrolled, footer: bottom) }
    }
}
