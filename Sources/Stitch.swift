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

    /// Per column: moves with the page (+1), stays put like a sidebar (-1), changes some other way
    /// like a scrollbar thumb (2), or can't tell because it's blank (0). Compares sampled rows of `next`
    /// with `prev` both shifted by `scrolled` and in place. Both buffers hold 32-bit pixels.
    static func columnVotes(prev: UnsafeRawBufferPointer, prevBytesPerRow: Int,
                            next: UnsafeRawBufferPointer, nextBytesPerRow: Int,
                            width: Int, height: Int, scrolled d: Int, top: Int, footer: Int) -> [Int8] {
        var votes = [Int8](repeating: 0, count: width)
        let checked = Array(stride(from: top, to: height - footer - d, by: 3)) // skip fixed bars
        guard d > 0, !checked.isEmpty else { return votes }
        let p = prev.baseAddress!, n = next.baseAddress!
        func pixel(_ base: UnsafeRawPointer, _ bpr: Int, _ y: Int, _ x: Int) -> UInt32 {
            base.load(fromByteOffset: y * bpr + x * 4, as: UInt32.self)
        }
        for x in 0..<width {
            var moved = 0, stayed = 0, informative = 0
            for y in checked {
                let now = pixel(n, nextBytesPerRow, y, x)
                let shifted = pixel(p, prevBytesPerRow, y + d, x), same = pixel(p, prevBytesPerRow, y, x)
                if now == shifted && now == same { continue } // blank here: no evidence either way
                informative += 1
                if now == shifted { moved += 1 } else if now == same { stayed += 1 }
            }
            guard informative >= 4 else { continue }
            // Half is enough to count as moving: a hover highlight sliding past costs a few rows.
            votes[x] = moved * 2 >= informative ? 1 : stayed * 10 >= informative * 7 ? -1 : 2
        }
        return votes
    }

    /// The columns to keep: the ones that scrolled, widened left and right over padding (per
    /// `isPadding`) until a sidebar or the scrollbar at the right edge. Nil when nothing clearly
    /// scrolled: keep the whole width.
    static func span(moved: [Int], stayed: [Int], conflicted: [Int], scrollbar: Int,
                     isPadding: (Int) -> Bool = { _ in true }) -> Range<Int>? {
        let w = moved.count
        // A third is enough: a hover highlight sliding past adds noise, a sidebar never moves.
        // The scrollbar's zone at the right edge never counts as scrolling by itself.
        let scrolls = (0..<w).map { $0 < w - scrollbar && moved[$0] >= 2 && moved[$0] * 2 >= stayed[$0] + conflicted[$0] }
        let fixed = { (x: Int) in stayed[x] >= 2 && stayed[x] > moved[x] * 2 }
        let thumb = { (x: Int) in x >= w - scrollbar && conflicted[x] >= 2 && conflicted[x] > moved[x] * 2 }
        guard var lo = scrolls.firstIndex(of: true), var hi = scrolls.lastIndex(of: true) else { return nil }
        while lo > 0, !fixed(lo - 1), scrolls[lo - 1] || isPadding(lo - 1) { lo -= 1 }
        while hi < w - 1, !fixed(hi + 1), !thumb(hi + 1), scrolls[hi + 1] || isPadding(hi + 1) { hi += 1 }
        if hi >= w - scrollbar, (w - scrollbar..<w).contains(where: thumb) { hi = min(hi, w - scrollbar - 1) } // never half a scrollbar
        return lo..<(hi + 1)
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
        step([prev], [next])
    }

    /// Lines up a frame cut into vertical strips. Each detailed strip proposes the shifts that fit
    /// it best, up or down; each proposal is then scored by how many rows agree across every strip
    /// that changed, and the best one wins. A strip that repeats (a column of avatars every three
    /// messages) fits several shifts, but strips with unique text only fit the real one, and a hover
    /// highlight or caret only costs a few rows instead of ruling the right shift out. Strips that
    /// didn't change (a sidebar) take no part. Scrolling up returns `scrolled == 0`: nothing to add.
    static func step(_ prev: [Rows], _ next: [Rows]) -> Match? {
        guard prev.count == next.count, let h = prev.first?.count, h > 0,
              prev.allSatisfy({ $0.count == h }), next.allSatisfy({ $0.count == h }) else { return nil }
        let changed = prev.indices.filter { prev[$0].hashes != next[$0].hashes }
        if changed.isEmpty { return Match(scrolled: 0, footer: 0) }

        // Rows that stay put across the whole width at the bottom: a footer or toolbar.
        let cap = h * 2 / 5
        var footer = 0
        while footer < cap, changed.allSatisfy({ prev[$0].hashes[h - 1 - footer] == next[$0].hashes[h - 1 - footer] }) { footer += 1 }

        var proposals = Set<Int>()
        for i in changed { proposals.formUnion(shifts(prev[i], next[i])) }

        // Score = how many strips line up, each counted by the share of its rows that agree.
        var best: (scrolled: Int, support: Double)?
        for d in proposals.sorted(by: { abs($0) < abs($1) }) {
            let support = changed.reduce(0.0) { total, i in
                total + (fit(prev[i], next[i], d, bottom: footer).map { Double($0.agree) / Double($0.informative) } ?? 0)
            }
            if support > (best?.support ?? 0.99) { best = (d, support) }
        }
        return best.map { Match(scrolled: max(0, $0.scrolled), footer: footer) }
    }

    /// The band at the top of a strip that's identical in place (a fixed header).
    private static func top(_ prev: Rows, _ next: Rows) -> Int {
        let cap = prev.count * 2 / 5
        var top = 0
        while top < cap, prev.hashes[top] == next.hashes[top] { top += 1 }
        return top
    }

    /// Shifts worth scoring for one strip: where a few distinctive rows of `next` sat in `prev`.
    /// Unique rows give the exact shift; rows that repeat give a handful of candidates.
    private static func shifts(_ prev: Rows, _ next: Rows) -> Set<Int> {
        var positions: [UInt64: [Int]] = [:]
        for (i, hash) in prev.hashes.enumerated() where !prev.flat[i] { positions[hash, default: []].append(i) }
        let informative = next.hashes.indices.filter { !next.flat[$0] }
        guard !informative.isEmpty else { return [] }
        var found = Set<Int>()
        for k in 0..<min(12, informative.count) {
            let a = informative[k * informative.count / min(12, informative.count)]
            for p in (positions[next.hashes[a]] ?? []).prefix(12) where p != a { found.insert(p - a) }
        }
        return found
    }

    /// How well `prev` shifted by `d` rows (up when positive) lines up with `next`: the number of
    /// informative rows that agree, or nil when fewer than half of them do.
    private static func fit(_ prev: Rows, _ next: Rows, _ d: Int, top: Int? = nil, bottom: Int) -> (agree: Int, informative: Int)? {
        let start = top ?? self.top(prev, next)
        let overlap = prev.count - start - bottom - abs(d)
        guard overlap >= max(24, (prev.count - start - bottom) / 6) else { return nil } // too little seen twice
        let allowed = overlap / 2
        var informative = 0, agree = 0, misses = 0
        for i in 0..<overlap {
            let a = start + max(d, 0) + i, b = start + max(-d, 0) + i
            if prev.flat[a] && next.flat[b] {
                if prev.hashes[a] != next.hashes[b] { misses += 1 }
            } else {
                informative += 1
                if prev.hashes[a] == next.hashes[b] { agree += 1 } else { misses += 1 }
            }
            if misses > allowed { return nil }
        }
        guard informative >= 8, agree * 2 >= informative else { return nil }
        return (agree, informative)
    }
}
