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
// Title Case keeps real spellings from the screenshot's text
check(TextRules.stem(words: ["github", "pr", "review"], style: .title, date: nil, casingSource: "Pull request · GitHub") == "GitHub Pr Review", "OCR spelling")
check(TextRules.stem(words: ["iphone", "pdf", "receipt", "usd"], style: .title, date: nil, casingSource: "iPhone 17 Pro\nReceipt.PDF\nTotal 999 USD") == "iPhone PDF Receipt USD", "brand and acronyms from OCR")
check(TextRules.stem(words: ["macOS", "ID", "ALICE"], style: .title, date: nil) == "macOS ID Alice", "own casing kept, long caps tamed")
check(TextRules.stem(words: ["sale"], style: .title, date: nil, casingSource: "SUMMER SALE\nShop now") == "Sale", "shouted headings ignored")
check(TextRules.stem(words: ["id"], style: .title, date: nil, casingSource: "Order ID\nYour Id card") == "Id", "plain sighting vetoes")
check(TextRules.stem(words: ["github"], style: .title, date: nil, casingSource: "GitHub\ngithub.com/spruce") == "GitHub", "lowercase URL doesn't veto")
check(TextRules.stem(words: ["github"], style: .kebab, date: nil, casingSource: "GitHub") == "github", "kebab stays lowercase")
check(TextRules.stem(words: ["slack"], style: .title, date: date) == "2026-11-02 Slack", "title date prefix")

// Hand-edited names
check(TextRules.normalizeEdited("iPhone 17 Pro", style: .title) == "iPhone 17 Pro", "user casing wins")
check(TextRules.normalizeEdited("2026-11-03 Slack Alice", style: .title) == "2026-11-03 Slack Alice", "date kept in title")
check(TextRules.normalizeEdited("2026-11-03_slack_alice", style: .snake) == "2026-11-03_slack_alice", "date kept in snake")
check(TextRules.normalizeEdited("2026-11-03 Slack Alice", style: .snake) == "2026-11-03_slack_alice", "snake lowercases edits")
check(TextRules.normalizeEdited("2026-11-03-slack", style: .kebab) == "2026-11-03-slack", "kebab unchanged")
check(TextRules.normalizeEdited(" ../My Notes! ", style: .title) == "My Notes", "edits sanitized")
check(TextRules.normalizeEdited("   ", style: .title) == nil, "empty edit")
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

// Text search: saved lines, tokens, matches, highlight boxes and snippets
do {
    let stored = TextRules.storedLines([
        OCRLine(text: "Wi-Fi password: Café4471", confidence: 0.9, box: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.05)),
        OCRLine(text: "noise", confidence: 0.2, box: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),
        OCRLine(text: "Invoice", confidence: 0.8, box: CGRect(x: 0.1, y: 0.8, width: 0.123456, height: 0.05)),
    ])
    check(stored.map(\.t) == ["Invoice", "Wi-Fi password: Café4471"], "low confidence dropped, reading order")
    check(stored[0].b[2] == 0.1235, "boxes rounded")
    let data = TextRules.encodeStored(stored)!
    check(TextRules.decodeStored(data) == stored, "round trip")
    let many = (0..<2000).map { StoredLine(t: "line number \($0) with some words", b: [0, 0, 1, 0.01]) }
    let capped = TextRules.encodeStored(many)!
    check(capped.count <= TextRules.storedTextCap && TextRules.decodeStored(capped)!.count > 100, "capped but not emptied")

    check(TextRules.searchTokens("  Invoice   4471 invoice ") == ["invoice", "4471"], "tokens folded and deduped")
    let text = SearchableText(stored)
    check(TextRules.search(["cafe"], name: "shot", text: text)?.boxes.count == 1, "diacritics folded")
    check(TextRules.search(["invoice", "4471"], name: "shot", text: text) != nil, "tokens across lines")
    check(TextRules.search(["invoice", "9999"], name: "shot", text: text) == nil, "every token must appear")
    check(TextRules.search(["slack", "4471"], name: "slack-chat", text: text) != nil, "name and text together")
    let nameOnly = TextRules.search(["slack"], name: "slack-chat", text: nil)
    check(nameOnly == TextHit(), "name match without text: no boxes, no snippet")
    let hit = TextRules.search(["password"], name: "shot", text: text)!
    check(hit.snippet == "Wi-Fi password: Café4471", "snippet is the matching line")
    let box = hit.boxes[0], line = stored[1].box
    check(box.minX > line.minX && box.maxX < line.maxX && box.minY == line.minY, "highlight narrowed to the word")
    let long = "aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee ffffffffff target gggggggggg hhhhhhhhhh"
    let s = TextRules.snippet(long, folded: long, at: long.range(of: "target")!.lowerBound)
    check(s.hasPrefix("…") && s.contains("target") && s.count <= 62, "long line cut around the match: \(s)")
}

print("All checks passed.")
