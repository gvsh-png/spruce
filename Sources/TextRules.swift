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

    // MARK: Sensitive text

    /// Parts of one OCR line that look private: email addresses, phone numbers, card numbers (Luhn-checked),
    /// IBANs (checksum-checked), API keys and tokens, JWTs. Overlapping matches are merged.
    /// The pill's Redact button covers exactly these.
    static func sensitiveRanges(_ s: String) -> [Range<String.Index>] {
        let whole = NSRange(s.startIndex..., in: s)
        var found: [Range<String.Index>] = []
        for (pattern, valid) in sensitivePatterns {
            for match in pattern.matches(in: s, range: whole) {
                guard let range = Range(match.range, in: s), valid(String(s[range])) else { continue }
                found.append(range)
            }
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
