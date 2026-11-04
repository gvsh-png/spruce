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
    /// In Title Case, words spelled with their own capitals in `casingSource` (the OCR text)
    /// keep that spelling: "github" -> "GitHub" when the screenshot says GitHub.
    /// Returns nil when nothing usable is left.
    static func stem(words: [String], style: NamingStyle, date: Date?, casingSource: String? = nil,
                     maxLength: Int = maxNameLength) -> String? {
        let spellings = style == .title ? knownSpellings(casingSource ?? "") : [:]
        let tokens = sanitizedTokens(words).map { cased($0, style, spellings) }
        guard !tokens.isEmpty else { return nil }
        return joined(tokens, prefix: date.map { dayFormatter.string(from: $0) } ?? "", style: style, maxLength: maxLength)
    }

    /// Makes a hand-edited name safe without re-casing it in Title Case (the user's spelling wins)
    /// and keeps a leading "yyyy-MM-dd" date as typed. Kebab and snake are still lowercased.
    static func normalizeEdited(_ stem: String, style: NamingStyle, maxLength: Int = maxNameLength) -> String? {
        let typed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(typed)
        var prefix = ""
        if let r = typed.range(of: #"^\d{4}-\d{2}-\d{2}(?!\d)"#, options: .regularExpression) {
            prefix = String(typed[r])
            rest = typed[r.upperBound...]
        }
        let tokens = sanitizedTokens([String(rest)]).map { style == .title ? $0 : $0.lowercased() }
        if tokens.isEmpty { return prefix.isEmpty ? nil : prefix }
        return joined(tokens, prefix: prefix, style: style, maxLength: maxLength)
    }

    /// Words with only letters and digits left, diacritics folded and apostrophes dropped.
    private static func sanitizedTokens(_ words: [String]) -> [String] {
        words
            .map {
                $0.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\u{2019}", with: "")
            }
            .flatMap { $0.split { !($0.isLetter || $0.isNumber) }.map(String.init) }
    }

    /// Joins tokens after `prefix` with the style's separator, stopping at a word boundary
    /// before `maxLength`. `tokens` must not be empty.
    private static func joined(_ tokens: [String], prefix: String, style: NamingStyle, maxLength: Int) -> String {
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

    // MARK: Sensitive text

    /// Parts of one OCR line that look private: email addresses, phone numbers, card numbers (Luhn-checked),
    /// IBANs (checksum-checked), API keys and tokens, JWTs. Overlapping matches are merged.
    /// The pill's Redact button covers exactly these.
    static func sensitiveRanges(_ line: String) -> [Range<String.Index>] {
        // Vision sometimes reads code with lookalikes (Cyrillic "А", "х", an em dash for "-"). Match on
        // a plain-ASCII copy with one character per character, then map the ranges back to `line`.
        let original = Array(line.indices)
        let s = String(line.map { lookalikes[$0] ?? $0 })
        guard s.count == original.count else { return sensitiveMatches(line) }
        let offsets = Dictionary(uniqueKeysWithValues: zip(s.indices, 0...))
        return sensitiveMatches(s).compactMap { r in
            guard let lo = offsets[r.lowerBound] else { return nil }
            let hi = offsets[r.upperBound].map { original[$0] } ?? line.endIndex
            return original[lo]..<hi
        }
    }

    private static let lookalikes: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X",
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
        "—": "-", "–": "-", "‐": "-", "‑": "-", "−": "-",
    ]

    private static func sensitiveMatches(_ s: String) -> [Range<String.Index>] {
        let whole = NSRange(s.startIndex..., in: s)
        var found: [Range<String.Index>] = []
        for (pattern, valid) in sensitivePatterns {
            for match in pattern.matches(in: s, range: whole) {
                guard let range = Range(match.range, in: s), valid(String(s[range])) else { continue }
                found.append(range)
            }
        }
        // Values written after a label like API_KEY=, token: or Secret = are secret whatever their shape,
        // even when OCR has mangled a known prefix ("sk-" read as "51").
        for match in labeledSecret.matches(in: s, range: whole) {
            guard let range = Range(match.range(at: 1), in: s) else { continue }
            let value = s[range]
            if value.count >= 16, value.contains(where: \.isLetter), value.contains(where: \.isNumber) { found.append(range) }
        }
        // IBANs: the spaced form can run into the next word ("… 0130 00 EUR"), so drop trailing groups until it checks out.
        for match in ibanPattern.matches(in: s, range: whole) {
            guard var range = Range(match.range, in: s) else { continue }
            while !isIBAN(String(s[range])) {
                guard let space = s[range].lastIndex(of: " ") else { range = range.lowerBound..<range.lowerBound; break }
                range = range.lowerBound..<space
            }
            if !range.isEmpty { found.append(range) }
        }
        var merged: [Range<String.Index>] = []
        for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern) // literals below; a typo fails the self-check at once
    }

    private static let sensitivePatterns: [(NSRegularExpression, (String) -> Bool)] = [
        // Email addresses.
        (regex(#"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#), { _ in true }),
        // Card numbers: 13–19 digits, optionally in groups of 3–6, passing the Luhn check.
        (regex(#"(?<![\d\-])\d(?:[ \-]?\d){12,18}(?![\d\-])"#), isCardNumber),
        // Phone numbers: international (+47 912 34 567) or North American ((415) 555-0132, 415-555-0132).
        (regex(#"(?<![\w+])(?:\+\d{1,3}[ .\-]?)?\(?\d{2,4}\)?(?:[ .\-]?\d{2,4}){2,4}(?![\w])"#), isPhoneNumber),
        // Known key and token shapes: OpenAI/Anthropic, Stripe, GitHub, Slack, AWS, Google, GitLab, JWT.
        (regex(#"(?<![A-Za-z0-9_\-])(?:sk-(?:proj-|ant-)?[A-Za-z0-9_\-]{20,}|(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9\-]{10,}|A(?:KIA|SIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35}|glpat-[A-Za-z0-9_\-]{20,}|eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})"#), { _ in true }),
        // Any other long random-looking string: 32+ characters mixing upper, lower and digits.
        (regex(#"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9_\-])"#), isRandomToken),
    ]

    private static let labeledSecret = regex(#"(?i)(?:key|ke|token|secret|passw(?:or)?d|pwd|auth|bearer)["']?\s*[=:]\s*["']?([A-Za-z0-9_\-+/.=]{16,})"#)

    private static let ibanPattern = regex(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{1,4}){3,8})(?![A-Za-z0-9])"#)

    static func isCardNumber(_ s: String) -> Bool {
        let groups = s.split { $0 == " " || $0 == "-" }
        guard groups.count == 1 || groups.allSatisfy({ (3...6).contains($0.count) }) else { return false } // "4242 4242 …", not two numbers side by side
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            let v = i % 2 == 1 ? d * 2 : d
            sum += v > 9 ? v - 9 : v
        }
        return sum % 10 == 0
    }

    static func isPhoneNumber(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count
        guard (9...15).contains(digits) else { return false }
        // A leading + or the North American shape; anything else is more likely a date, ID or amount.
        return s.hasPrefix("+") || s.range(of: #"^\(?\d{3}\)?[ .\-]?\d{3}[ .\-]\d{4}$"#, options: .regularExpression) != nil
    }

    static func isIBAN(_ s: String) -> Bool {
        let compact = s.filter { $0 != " " }
        guard (15...34).contains(compact.count) else { return false }
        // ISO 13616: move the first four characters to the end, letters become 10–35, the number mod 97 is 1.
        var remainder = 0
        for c in compact.dropFirst(4) + compact.prefix(4) {
            guard let value = c.wholeNumberValue ?? c.unicodeScalars.first.flatMap({ c.isASCII && c.isUppercase ? Int($0.value) - 55 : nil })
            else { return false }
            for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }

    static func isRandomToken(_ s: String) -> Bool {
        s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase)
            && s.filter(\.isNumber).count >= 4 && Set(s).count >= 14
    }

    // MARK: Helpers

    private static func cased(_ token: String, _ style: NamingStyle, _ spellings: [String: String]) -> String {
        guard style == .title else { return token.lowercased() }
        if let known = spellings[token.lowercased()] { return known }
        if hasOwnCasing(token) { return token }
        return token.prefix(1).uppercased() + token.dropFirst().lowercased()
    }

    /// "GitHub", "iPhone", "macOS" (capitals after a lowercase letter) or a short acronym like "PDF".
    /// Longer all-caps words ("ALICE", "TOTAL") are shouting, not spelling.
    private static func hasOwnCasing(_ token: String) -> Bool {
        let rest = token.dropFirst()
        if rest.contains(where: \.isUppercase) && token.contains(where: \.isLowercase) { return true }
        return (2...4).contains(token.count) && token.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// Lowercased word -> its spelling in the OCR text, for words that carry their own casing.
    /// Skips all-caps headings ("ORDER SUMMARY") and words also seen capitalized plainly ("Total" and "TOTAL").
    /// All-lowercase sightings ("github.com" in a URL bar) don't count against a spelling.
    static func knownSpellings(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        var plain = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let shouted = !line.contains(where: \.isLowercase)
            for token in sanitizedTokens([String(line)]) {
                let key = token.lowercased()
                if hasOwnCasing(token) && !(shouted && token.allSatisfy(\.isUppercase)) {
                    if map[key] == nil { map[key] = token }
                } else if token.first?.isUppercase == true && token.contains(where: \.isLowercase) {
                    plain.insert(key)
                }
            }
        }
        return map.filter { !plain.contains($0.key) }
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
