// Self-check for the pure naming rules. Needs only the Command Line Tools:
//   swiftc Sources/TextRules.swift Tests/main.swift -o /tmp/selfcheck && /tmp/selfcheck
import Foundation

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what)"); exit(1) }
}

let date = TextRules.dayFormatter.date(from: "2026-11-02")!

// Formatting and sanitizing
check(TextRules.stem(words: ["Slack", "Alice's", "Q3 budget!"], style: .kebab, date: nil) == "slack-alices-q3-budget", "kebab")
check(TextRules.stem(words: ["Slack", "Alice"], style: .snake, date: nil) == "slack_alice", "snake")
check(TextRules.stem(words: ["slack", "ALICE"], style: .title, date: nil) == "Slack Alice", "title")
check(TextRules.stem(words: ["Café", "Menü"], style: .kebab, date: nil) == "cafe-menu", "diacritics folded")
check(TextRules.stem(words: ["../../etc/passwd"], style: .kebab, date: nil) == "etc-passwd", "no path characters survive")
check(TextRules.stem(words: ["日本語", "メモ"], style: .kebab, date: nil) == "日本語-メモ", "non-Latin kept")
check(TextRules.stem(words: ["receipt"], style: .kebab, date: date) == "2026-11-02-receipt", "date prefix")
check(TextRules.stem(words: ["!!!", "  "], style: .kebab, date: nil) == nil, "nothing usable")
check(TextRules.stem(words: [], style: .kebab, date: nil) == nil, "empty")

let long = TextRules.stem(words: Array(repeating: "budget", count: 30), style: .kebab, date: nil)!
check(long.count <= 80 && long.hasSuffix("budget"), "truncates at a word boundary")
let oneHuge = TextRules.stem(words: [String(repeating: "a", count: 200)], style: .kebab, date: date)!
check(oneHuge.count == 80 && oneHuge.hasPrefix("2026-11-02-a"), "single huge word cut")

check(TextRules.fallbackStem(app: "Xcode", date: TextRules.minuteFormatter.date(from: "2026-11-02-1234")!, style: .kebab) == "xcode-2026-11-02-1234", "fallback")
check(TextRules.fallbackStem(app: nil, date: date, style: .kebab).hasPrefix("screenshot-2026-11-02"), "fallback without app")

// Collisions
let dir = URL(fileURLWithPath: "/tmp/x")
let taken: Set = ["/tmp/x/a.png", "/tmp/x/a-2.png"]
check(TextRules.uniqueURL(in: dir, stem: "a", ext: "png", separator: "-") { taken.contains($0.path) }.path == "/tmp/x/a-3.png", "collision numbering")
check(TextRules.uniqueURL(in: dir, stem: "b", ext: "png", separator: "-") { taken.contains($0.path) }.path == "/tmp/x/b.png", "free name")

// Model output
check(TextRules.parseSuggestion("Sure!\n```json\n{\"words\":[\"a\",\"b\"],\"folder\":null}\n```") == Suggestion(words: ["a", "b"], folder: nil), "JSON inside prose")
check(TextRules.parseSuggestion("{\"words\":[],\"folder\":null}") == nil, "empty words rejected")
check(TextRules.parseSuggestion("no json here") == nil, "no JSON")
check(TextRules.matchFolder(" receipts ", allowed: ["Receipts", "Work"]) == "Receipts", "folder match")
check(TextRules.matchFolder("Invoices", allowed: ["Receipts"]) == nil, "invented folder rejected")
check(TextRules.matchFolder(nil, allowed: ["Receipts"]) == nil, "null folder")

// OCR ranking
let lines = [
    OCRLine(text: "File Edit View", confidence: 0.9, box: CGRect(x: 0, y: 0.98, width: 0.2, height: 0.01)),
    OCRLine(text: "Q3 Budget Review", confidence: 0.95, box: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.06)),
    OCRLine(text: "garbled", confidence: 0.2, box: CGRect(x: 0, y: 0.5, width: 0.1, height: 0.05)),
    OCRLine(text: "q3 budget review", confidence: 0.9, box: CGRect(x: 0, y: 0.3, width: 0.1, height: 0.02)),
]
check(TextRules.rankedText(lines) == "File Edit View\nQ3 Budget Review", "drops low confidence and duplicates, keeps reading order")
check(TextRules.rankedText(lines, budget: 20) == "Q3 Budget Review", "tight budget keeps the big title")
check(TextRules.rankedText([]) == "", "no text")

check(TextRules.cleaned(Suggestion(words: ["orca", "Screenshot"], folder: nil)) == Suggestion(words: ["orca"], folder: nil), "banned word dropped")
check(TextRules.cleaned(Suggestion(words: ["image"], folder: nil)) == nil, "only banned words")
check(TextRules.cleaned(Suggestion(words: ["Screenshot:", "screen-shot", "slack"], folder: nil)) == Suggestion(words: ["slack"], folder: nil), "banned words with punctuation dropped")
check(TextRules.cleaned(Suggestion(words: (1...12).map(String.init), folder: nil))?.words.count == 7, "capped at 7 words")
check(TextRules.cleaned(Suggestion(words: ["invoice northwind hosting", "alex jensen", "cloud server m2", "october"], folder: nil))?.words.count == 7, "multi-word entries count each word")

check(TextRules.looksDefaultName("Screenshot 2026-10-30 at 14.09.49.png"), "English default name")
check(TextRules.looksDefaultName("Bildschirmfoto 2026-10-30 um 14.09.49.png"), "German default name")
check(!TextRules.looksDefaultName("invoice-northwind.png"), "renamed file left alone")
check(TextRules.matchKind("receipt") == "Receipt" && TextRules.matchKind("Other") == nil && TextRules.matchKind("Banana") == nil, "kinds")
check(TextRules.fullText(lines) == "File Edit View\nQ3 Budget Review\nq3 budget review", "full text keeps everything readable in order")

let shot = TextRules.wordSet("def beregn_lonn(timelonn, antall_timer): return timelonn * antall_timer def hent_input(): print hent_input")
let edited = TextRules.wordSet("def beregn_lonn(timelonn, antall_timer): return timelonn * antall_timer def lonnverdier(): print lonnverdier")
check(TextRules.isBurst(shot, shot), "identical text is a burst")
check(!TextRules.isBurst(shot, TextRules.wordSet("invoice northwind hosting total due alex jensen cloud server backup")), "different text is not")
check(!TextRules.isBurst(TextRules.wordSet("ok"), TextRules.wordSet("ok")), "text-free shots never collapse")
check(TextRules.isBurst(shot, edited) == (Double(shot.intersection(edited).count) / Double(shot.union(edited).count) >= 0.7), "threshold applied")

// Sensitive text (Redact)
func sensitive(_ s: String) -> [String] { TextRules.sensitiveRanges(s).map { String(s[$0]) } }
check(sensitive("Write to alice.jensen@northwind.io today") == ["alice.jensen@northwind.io"], "email")
check(sensitive("Card 4242 4242 4242 4242 exp 12/28") == ["4242 4242 4242 4242"], "card number")
check(sensitive("Card 4242 4242 4242 4241").isEmpty, "card number failing Luhn")
check(sensitive("Call +47 912 34 567 or (415) 555-0132") == ["+47 912 34 567", "(415) 555-0132"], "phone numbers")
check(sensitive("IBAN DE89 3704 0044 0532 0130 00 EUR") == ["DE89 3704 0044 0532 0130 00"], "spaced IBAN stops before the next word")
check(sensitive("GB82WEST12345698765432") == ["GB82WEST12345698765432"], "compact IBAN")
check(sensitive("GB82WEST12345698765433").isEmpty, "IBAN with a bad checksum")
check(sensitive("export OPENAI_API_KEY=sk-proj-a1B2c3D4e5F6g7H8i9J0kLmN") == ["sk-proj-a1B2c3D4e5F6g7H8i9J0kLmN"], "API key")
check(sensitive("token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789 ok") == ["ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"], "GitHub token")
check(sensitive("AKIAIOSFODNN7EXAMPLE") == ["AKIAIOSFODNN7EXAMPLE"], "AWS key")
let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
check(sensitive("Bearer \(jwt)") == [jwt], "JWT is one range")
check(sensitive("secret x7Kp2Lm9Qr4Tv8Wz1Bn5Cd3Fg6Hj0Ys2Ae") == ["x7Kp2Lm9Qr4Tv8Wz1Bn5Cd3Fg6Hj0Ys2Ae"], "random-looking token")
for safe in ["Screenshot 2026-10-30 at 14.09.49", "macOS 14.2.1 (23C71) build 1234567890", "Order #12345678 total $1,234.56",
             "commit a94a8fe5ccb19ba61c4c0873d391e987982fbbd3", "spruce-one-click-auto-redact-for-screenshots-v2",
             "Meeting 10:30-11:45 room 4", "risk-assessment-framework-for-the-whole-team", "Version 1.2.3.4567 released 2026.11.02",
             "Ticket ID 12 345 678", ""] {
    check(sensitive(safe).isEmpty, "nothing sensitive in \"\(safe)\": \(sensitive(safe))")
}

// Prompt
check(Prompt.system(folders: ["Receipts"]).contains("\"Receipts\""), "folders listed in prompt")
check(Prompt.system(folders: []).contains("Always set \"folder\" to null"), "no folders")


// Scroll capture stitching: a page of unique rows, a 10-row sticky header and a 6-row footer.
do {
    let page = (0..<400).map { UInt64($0) &* 2_654_435_761 &+ 7 }
    let header = (0..<10).map { UInt64(1_000_000 + $0) }, footer = (0..<6).map { UInt64(2_000_000 + $0) }
    func frame(_ offset: Int) -> Stitch.Rows {
        let hashes = header + Array(page[offset..<offset + 80]) + footer
        return Stitch.Rows(hashes: hashes, flat: hashes.map { _ in false })
    }
    check(Stitch.match(frame(0), frame(0)) == Stitch.Match(scrolled: 0, footer: 0), "unchanged frame")
    check(Stitch.match(frame(0), frame(17)) == Stitch.Match(scrolled: 17, footer: 6), "scrolled 17 rows past a header and footer")
    check(Stitch.match(frame(0), frame(79)) == nil, "scrolled too far to line up")
    check(Stitch.match(frame(30), frame(10))?.scrolled == 0, "scrolling up adds nothing")

    // Stitch a whole session and compare with the real page.
    var out = frame(0).hashes, last = frame(0)
    for offset in stride(from: 16, through: 320, by: 16) {
        let next = frame(offset)
        guard let m = Stitch.match(last, next) else { check(false, "lost track at \(offset)"); break }
        let (drop, rows) = Stitch.splice(height: next.count, m)
        out.removeLast(drop)
        out += next.hashes[rows]
        last = next
    }
    check(out == header + Array(page[0..<400]) + footer, "stitched page equals the original")
    let all = Stitch.Rows(hashes: out, flat: out.map { _ in false })
    check(Stitch.contains(all, frame(120)), "a frame from higher up is already captured")
    let unseen = (0..<96).map { UInt64(9_000_000 + $0) }
    check(!Stitch.contains(all, Stitch.Rows(hashes: unseen, flat: unseen.map { _ in false })), "new content is not")

    // Blank rows (a white gap in the page) never decide a match on their own.
    let blank = Stitch.Rows(hashes: Array(repeating: 5, count: 96), flat: Array(repeating: true, count: 96))
    check(Stitch.match(blank, blank) == Stitch.Match(scrolled: 0, footer: 0), "blank frames are unchanged")
}
// A chat whose avatar column repeats every 3 messages: the text strips must outvote it.
do {
    let messages = 120, rowsPerMessage = 12, h = 96
    // Avatar strip: one of three colors per message. Text strip: unique per message and line.
    let avatars = (0..<messages * rowsPerMessage).map { UInt64(($0 / rowsPerMessage) % 3 + 1) * 1_000 + UInt64($0 % rowsPerMessage) }
    let text = (0..<messages * rowsPerMessage).map { UInt64($0) &* 2_654_435_761 &+ 99 }
    let sidebar = (0..<h).map { UInt64(5_000_000 + $0) }
    func frame(_ offset: Int) -> [Stitch.Rows] {
        [Stitch.Rows(hashes: sidebar, flat: sidebar.map { _ in false }),
         Stitch.Rows(hashes: Array(avatars[offset..<offset + h]), flat: Array(repeating: false, count: h)),
         Stitch.Rows(hashes: Array(text[offset..<offset + h]), flat: Array(repeating: false, count: h))]
    }
    check(Stitch.step(frame(0), frame(14)) == Stitch.Match(scrolled: 14, footer: 0), "text outvotes the repeating avatar column")
    check(Stitch.step(frame(36), frame(36)) == Stitch.Match(scrolled: 0, footer: 0), "a sidebar alone doesn't count as scrolling")
}

// Column votes: a sidebar (columns 0–1) stays, the page (2–6) scrolls, a scrollbar (7) flickers.
do {
    let w = 8, h = 60, d = 9
    func pixels(offset: Int, thumb: UInt32) -> [UInt32] {
        (0..<h).flatMap { y in
            (0..<w).map { x -> UInt32 in
                switch x {
                case 0, 1: UInt32(100_000 + y * 7 + x)              // sidebar: the same in every frame
                case 7: thumb &+ UInt32(y % 5)                       // scrollbar: different every frame
                default: UInt32((y + offset) * 31 + x) &* 2_654_435_761 // page content
                }
            }
        }
    }
    let prev = pixels(offset: 0, thumb: 1), next = pixels(offset: d, thumb: 50)
    let votes = prev.withUnsafeBytes { p in next.withUnsafeBytes { n in
        Stitch.columnVotes(prev: p, prevBytesPerRow: w * 4, next: n, nextBytesPerRow: w * 4, width: w, height: h, scrolled: d, top: 0, footer: 0)
    } }
    check(votes == [-1, -1, 1, 1, 1, 1, 1, 2], "sidebar stays, page scrolls, scrollbar conflicts: \(votes)")
    let moved = votes.map { $0 == 1 ? 5 : 0 }, stayed = votes.map { $0 == -1 ? 5 : 0 }, conflicted = votes.map { $0 == 2 ? 5 : 0 }
    check(Stitch.span(moved: moved, stayed: stayed, conflicted: conflicted, scrollbar: 1) == 2..<7, "crop keeps only the scrolling columns")
    check(Stitch.span(moved: [0, 0], stayed: [0, 0], conflicted: [0, 0], scrollbar: 1) == nil, "nothing scrolled: keep everything")
}

print("All checks passed.")
