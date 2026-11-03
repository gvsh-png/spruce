import Foundation
import CoreGraphics

// Pure rules used by the pipeline. No AppKit, Vision or network here, so
// `Tests/main.swift` can compile this file with plain `swiftc` and check it.

enum NamingStyle: String, Codable, CaseIterable, Identifiable {
    case kebab, snake, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kebab: "kebab-case"
        case .snake: "snake_case"
        case .title: "Title Case"
        }
    }
    var separator: String {
        switch self {
        case .kebab: "-"
        case .snake: "_"
        case .title: " "
        }
    }
}

/// One line of OCR output. `box` uses Vision's normalized coordinates (0...1, origin bottom-left).
struct OCRLine {
    var text: String
    var confidence: Float
    var box: CGRect
}

/// One OCR line as saved next to the file (an extended attribute), for "Search names and text".
/// Short keys keep the JSON small: `t` is the text, `b` the Vision box as [x, y, width, height].
struct StoredLine: Codable, Hashable {
    var t: String
    var b: [Double]

    var box: CGRect { b.count == 4 ? CGRect(x: b[0], y: b[1], width: b[2], height: b[3]) : .zero }
}

/// A screenshot's saved lines, folded once so searching stays fast while you type.
struct SearchableText: Hashable {
    let lines: [StoredLine]
    let folded: [String]

    init(_ lines: [StoredLine]) {
        self.lines = lines
        folded = lines.map { TextRules.fold($0.t) }
    }
}

/// Why a screenshot matched a search: the boxes to highlight on its thumbnail, and one line to show.
struct TextHit: Equatable {
    var boxes: [CGRect] = []
    var snippet: String?
}

/// What the model answers with. The app turns `words` into a filename itself,
/// so casing, length and safe characters never depend on the model.
struct Suggestion: Codable, Equatable {
    var words: [String]
    var folder: String?
    /// One of `TextRules.kinds`; becomes a Finder tag.
    var kind: String? = nil
}

enum TextRules {
    static let maxNameLength = 80
    static let ocrBudget = 1500
    /// Below this many characters of OCR text, a small image is offered to the model instead.
    static let thinTextThreshold = 20

    // MARK: OCR text selection

    /// Picks the lines most likely to describe the screenshot, up to `budget` characters,
    /// returned in reading order. Taller text and text nearer the top (window titles,
    /// headings) wins over small UI chrome when the budget is tight.
    static func rankedText(_ lines: [OCRLine], budget: Int = ocrBudget) -> String {
        var seen = Set<String>()
        let candidates = lines
            .filter { $0.confidence >= 0.4 && $0.text.trimmingCharacters(in: .whitespaces).count >= 2 }
            .filter { seen.insert($0.text.lowercased()).inserted }
            .sorted { score($0) > score($1) }

        var picked: [OCRLine] = []
        var used = 0
        for line in candidates where used + line.text.count + 1 <= budget {
            picked.append(line)
            used += line.text.count + 1
        }
        return readingOrder(picked).map(\.text).joined(separator: "\n")
    }

    /// All readable lines in reading order, for "Copy Text".
    static func fullText(_ lines: [OCRLine]) -> String {
        readingOrder(lines.filter { $0.confidence >= 0.3 }).map(\.text).joined(separator: "\n")
    }

    static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        lines.sorted { a, b in
            let sameRow = abs(a.box.maxY - b.box.maxY) <= 0.01
            return sameRow ? a.box.minX < b.box.minX : a.box.maxY > b.box.maxY
        }
    }

    /// True for names the system gave ("Screenshot 2026-10-30 at 14.09.49"), in any language:
    /// they all contain the capture date and time. Bulk rename only touches these.
    static func looksDefaultName(_ name: String) -> Bool {
        name.range(of: #"\d{4}-\d{2}-\d{2}.*\d{1,2}[.:]\d{2}[.:]\d{2}"#, options: .regularExpression) != nil
    }

    // MARK: Text search

    /// Saved text is capped so the extended attribute stays small.
    static let storedTextCap = 32_000

    /// The lines worth saving: readable ones, with boxes rounded to keep the JSON short.
    static func storedLines(_ lines: [OCRLine]) -> [StoredLine] {
        func r(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
        return readingOrder(lines.filter { $0.confidence >= 0.4 && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { StoredLine(t: $0.text, b: [r($0.box.minX), r($0.box.minY), r($0.box.width), r($0.box.height)]) }
    }

    /// JSON for the extended attribute, dropping lines from the end until it fits under the cap.
    static func encodeStored(_ lines: [StoredLine], cap: Int = storedTextCap) -> Data? {
        var lines = lines
        while true {
            guard let data = try? JSONEncoder().encode(lines) else { return nil }
            if data.count <= cap || lines.isEmpty { return data }
            lines.removeLast(max(1, lines.count / 10))
        }
    }

    static func decodeStored(_ data: Data) -> [StoredLine]? {
        try? JSONDecoder().decode([StoredLine].self, from: data)
    }

    /// Case, accent and width insensitive form used on both sides of a search.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// "Invoice  4471" → ["invoice", "4471"]; every token must appear for a match.
    static func searchTokens(_ query: String) -> [String] {
        var seen = Set<String>()
        return fold(query).split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0).inserted }
    }

    /// Matches when every token is in the name or somewhere in the text. Returns nil for no match,
    /// otherwise where the tokens sit in the text (a box per occurrence) and the line that holds most of them.
    static func search(_ tokens: [String], name: String, text: SearchableText?, maxBoxes: Int = 40) -> TextHit? {
        let foldedName = fold(name)
        let folded = text?.folded ?? []
        for token in tokens where !foldedName.contains(token) && !folded.contains(where: { $0.contains(token) }) {
            return nil
        }
        var hit = TextHit()
        guard let text else { return hit }
        var best: (index: Int, count: Int, at: String.Index)?
        for (i, line) in folded.enumerated() {
            var count = 0
            var first: String.Index?
            for token in tokens {
                var from = line.startIndex
                var found = false
                while from < line.endIndex, let range = line.range(of: token, range: from..<line.endIndex) {
                    if !found { found = true; count += 1 }
                    if first == nil || range.lowerBound < first! { first = range.lowerBound }
                    if hit.boxes.count < maxBoxes { hit.boxes.append(subBox(text.lines[i].box, in: line, range: range)) }
                    from = range.upperBound
                }
            }
            if count > 0, let first, count > (best?.count ?? 0) { best = (i, count, first) }
        }
        if let best { hit.snippet = snippet(text.lines[best.index].t, folded: folded[best.index], at: best.at) }
        return hit
    }

    /// The part of a line's box that holds `range`, assuming characters of roughly even width
    /// (the box is for the whole line; the per-word boxes aren't saved). Half a character of slack each side.
    static func subBox(_ box: CGRect, in line: String, range: Range<String.Index>) -> CGRect {
        let n = Double(line.count)
        guard n > 0 else { return box }
        let start = Double(line.distance(from: line.startIndex, to: range.lowerBound)) / n
        let end = Double(line.distance(from: line.startIndex, to: range.upperBound)) / n
        let x0 = max(0, start - 0.5 / n), x1 = min(1, end + 0.5 / n)
        return CGRect(x: box.minX + box.width * x0, y: box.minY, width: box.width * (x1 - x0), height: box.height)
    }

    /// One line, cut to about 60 characters around the match.
    static func snippet(_ line: String, folded: String, at: String.Index, length: Int = 60) -> String {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard line.count > length else { return text }
        // Folding can change the length (ß → ss); only then fall back to the start of the line.
        var offset = line.count == folded.count ? folded.distance(from: folded.startIndex, to: at) : 0
        offset = max(0, min(offset - 12, line.count - length))
        let start = line.index(line.startIndex, offsetBy: offset)
        let cut = String(line[start...].prefix(length)).trimmingCharacters(in: .whitespaces)
        return (offset > 0 ? "…" : "") + cut + (offset + length < line.count ? "…" : "")
    }

    // MARK: Bursts

    /// Words of 3+ letters, lowercased: the fingerprint used to spot near-duplicate screenshots.
    static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count > 2 })
    }

    /// Two screenshots of the same thing: enough text in both, and at least 70% of words shared.
    /// Measured on real screenshots taken under a minute apart: unrelated pairs share 0–38%,
    /// near-duplicates 54–100%. Text-free images are never treated as bursts.
    static func isBurst(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard a.count >= 8, b.count >= 8 else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.7
    }

    /// Finder tags the model may choose from. "Other" means no tag.
    static let kinds = ["Chat", "Code", "Receipt", "Document", "Design", "Web", "Email", "Social", "Video", "Map", "Other"]

    static func matchKind(_ answer: String?) -> String? {
        matchFolder(answer, allowed: kinds).flatMap { $0 == "Other" ? nil : $0 }
    }

    // ponytail: size-and-position heuristic; swap for a learned ranker only if names stay poor on real data.
    static func score(_ line: OCRLine) -> Double {
        Double(line.box.height) * (1 + 0.5 * Double(line.box.maxY))
    }

    // MARK: Filename building

    /// Turns model words into a filesystem-safe name without extension,
    /// e.g. ["Slack", "Alice's", "Q3 budget!"] -> "slack-alices-q3-budget".
    /// Returns nil when nothing usable is left.
    static func stem(words: [String], style: NamingStyle, date: Date?, maxLength: Int = maxNameLength) -> String? {
        let tokens = words
            .map {
                $0.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\u{2019}", with: "")
            }
            .flatMap { $0.split { !($0.isLetter || $0.isNumber) }.map(String.init) }
            .map { cased($0, style) }
        guard !tokens.isEmpty else { return nil }

        let prefix = date.map { dayFormatter.string(from: $0) } ?? ""
        var out = prefix
        for token in tokens {
            let next = out.isEmpty ? token : out + style.separator + token
            if next.count > maxLength { break }
            out = next
        }
        if out == prefix { // the first word alone is too long: cut it
            let room = maxLength - (prefix.isEmpty ? 0 : prefix.count + style.separator.count)
            let cut = String(tokens[0].prefix(max(room, 1)))
            out = prefix.isEmpty ? cut : prefix + style.separator + cut
        }
        return out
    }

    /// Name used when OCR and AI give nothing: frontmost app plus capture time,
    /// e.g. "xcode-2026-11-02-1234".
    static func fallbackStem(app: String?, date: Date, style: NamingStyle) -> String {
        stem(words: [app ?? "screenshot", minuteFormatter.string(from: date)], style: style, date: nil)
            ?? "screenshot"
    }

    /// First free URL for `stem.ext` in `dir`: "name", then "name-2", "name-3"…
    static func uniqueURL(in dir: URL, stem: String, ext: String, separator: String, exists: (URL) -> Bool) -> URL {
        var n = 1
        while true {
            let base = n == 1 ? stem : "\(stem)\(separator)\(n)"
            let url = dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
            if !exists(url) { return url }
            n += 1
        }
    }

    // MARK: Model output

    /// Words the prompt forbids. Small models still use them, so drop them in code too.
    static let bannedWords: Set = ["screenshot", "screenshots", "image", "picture", "screen", "capture"]

    static let maxWords = 7

    /// Removes forbidden words and keeps at most `maxWords`. Returns nil when nothing is left.
    static func cleaned(_ s: Suggestion) -> Suggestion? {
        // Models sometimes pack several words into one entry ("cloud server m2"): split first, then cap.
        let words = s.words.flatMap { $0.split(separator: " ").map(String.init) }
            .filter { !bannedWords.contains($0.lowercased().filter(\.isLetter)) }.prefix(maxWords).map { $0 } // letters only: "Screenshot:", "screen-shot"
        return words.isEmpty ? nil : Suggestion(words: words, folder: s.folder, kind: s.kind)
    }

    /// Pulls the JSON object out of a model reply, tolerating prose or code fences around it.
    static func parseSuggestion(_ raw: String) -> Suggestion? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let suggestion = try? JSONDecoder().decode(Suggestion.self, from: data),
              !suggestion.words.isEmpty
        else { return nil }
        return suggestion
    }

    /// Accepts the model's folder only if it is one of the user's folders. The model never invents one.
    static func matchFolder(_ answer: String?, allowed: [String]) -> String? {
        guard let a = answer?.trimmingCharacters(in: .whitespaces).lowercased(), !a.isEmpty else { return nil }
        return allowed.first { $0.lowercased() == a }
    }

    // MARK: Helpers

    private static func cased(_ token: String, _ style: NamingStyle) -> String {
        style == .title ? token.prefix(1).uppercased() + token.dropFirst().lowercased() : token.lowercased()
    }

    static let dayFormatter = formatter("yyyy-MM-dd")
    static let minuteFormatter = formatter("yyyy-MM-dd-HHmm")
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

/// The versioned prompt. Bump `version` whenever the text changes; it is stored with every history entry.
enum Prompt {
    static let version = "v4"

    static func system(folders: [String]) -> String {
        let folderRule = folders.isEmpty
            ? "Always set \"folder\" to null."
            : "Folders: \(folders.map { "\"\($0)\"" }.joined(separator: ", ")). Set \"folder\" to the one that fits best whenever one reasonably fits (an invoice or receipt fits a receipts folder). Use null only when none fits."
        return """
        You name screenshot files. Read the text found in a screenshot and write a short title for it, 3 to 7 words, like a good document name.
        Rules:
        - Start with the app or website shown, when the text makes it clear (for example Slack, Gmail, Figma, Xcode).
        - Then the people, project, topic or document type. Keep it specific: "slack alice q3 budget review moved" beats "message team update".
        - Include a date, version number, amount or ID only when it is the point of the screenshot.
        - Never use the words screenshot, image, picture, screen or capture.
        - Ignore interface chrome such as menu names, button labels and toolbar text.
        - Set "kind" to the one that fits best: \(TextRules.kinds.joined(separator: ", ")).
        - \(folderRule)
        Reply with JSON only, no other text: {"words": ["word", "word"], "kind": "Other", "folder": null}
        Example for a Slack channel where Alice says the Q3 budget review moved to Thursday:
        {"words": ["slack", "alice", "q3", "budget", "review", "thursday"], "kind": "Chat", "folder": null}
        """
    }

    /// The frontmost app is deliberately not sent: models put it first even when the screenshot shows
    /// something else. It is used only for the fallback name.
    static func user(text: String, hasImage: Bool) -> String {
        var parts: [String] = []
        if text.isEmpty {
            parts.append(hasImage ? "The screenshot has almost no text. Describe it from the attached image." : "The screenshot has no readable text.")
        } else {
            parts.append("Text from the screenshot:\n<<<\n\(text)\n>>>")
            if hasImage { parts.append("A small copy of the screenshot is attached.") }
        }
        return parts.joined(separator: "\n\n")
    }
}
