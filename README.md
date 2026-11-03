<div align="center">

<img src="docs/media/icon.png" width="128" height="128" alt="Spruce icon">

# Spruce

**Your screenshots, named for you.**

Spruce reads each new screenshot on your Mac and gives it a real name, so<br>
`Screenshot 2026-11-03 at 10.12.00.png` becomes `booking-copenhagen-lisbon-flight-sk-2581.png`.

[![Latest release](https://img.shields.io/github/v/release/gvsh-png/spruce?style=flat-square&label=release&color=34c759)](https://github.com/gvsh-png/spruce/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-111111?style=flat-square)](#requirements)
[![On-device AI](https://img.shields.io/badge/AI-on--device-111111?style=flat-square)](#privacy)
[![Downloads](https://img.shields.io/github/downloads/gvsh-png/spruce/total?style=flat-square&color=111111)](https://github.com/gvsh-png/spruce/releases)

[Install](#install) · [Features](#features) · [Privacy](#privacy) · [AI models](#ai-models) · [FAQ](#faq)

<br>

<img src="docs/media/demo.gif" width="800" alt="A new screenshot appears in Spruce's pill at the top of the screen, and its name is written while you watch">

<sub>Take a screenshot. A small pill drops in, reads it, and names it. <a href="https://gvsh-png.github.io/spruce/media/demo.mp4">Watch in full quality</a>.</sub>

</div>

## Install

Paste this into Terminal:

```sh
curl -fsSL https://gvsh-png.github.io/spruce/install.sh | bash
```

Spruce installs into `/Applications`, opens, and lives in your menu bar. From then on it updates itself.

## Features

<table>
<tr>
<td width="50%" valign="top">

### ✏️ Names that make sense
Spruce reads the text in each screenshot on your Mac and asks an AI model for a short, searchable name. You see it being written, and you can click it to edit before it's saved.

</td>
<td width="50%" valign="top">

### 💊 A pill, not a popup
A slim black pill drops in near the top of the screen. It never steals focus and closes by itself after 5 seconds.

</td>
</tr>
<tr>
<td valign="top">

### ⚡️ One click for everything
**Copy**, **Copy Text**, **Move**, **Keep** and **Delete** sit right in the pill. Drag the thumbnail into any app. Hover it for a bigger preview.

</td>
<td valign="top">

### 🧹 Clutter cleans itself up
Screenshots are temporary by default: after 14 days they go to the Trash unless you kept, moved or sorted them. Bursts of near-identical shots collapse into one.

</td>
</tr>
<tr>
<td valign="top">

### 🗂️ Screenshot Manager
Browse every screenshot by day, week or month. Select a whole week and delete it in one go, with Undo.

</td>
<td valign="top">

### 🏷️ Sorted and tagged
Optional sorting into folders you choose, plus Finder tags by kind: Chat, Code, Receipt, Document, Design, Web, Email and more.

</td>
</tr>
<tr>
<td valign="top">

### 🔒 Private apps
Screenshots of password managers, Messages, or any app you add keep their original name. Nothing from them is read.

</td>
<td valign="top">

### ⏪ Undo anything
Every rename is logged. Undo the last one from the menu bar, or go back through the full history in Settings.

</td>
</tr>
</table>

<p align="center">
  <img src="docs/media/naming.png" width="420" alt="Spruce's pill while it reads a screenshot">
  <img src="docs/media/renamed.png" width="420" alt="Spruce's pill after naming the screenshot">
</p>

Also: copies every screenshot to the clipboard the moment it's saved, renames your old screenshots in one batch, and gives a small trackpad tick when a name lands.

## Privacy

- **On your Mac by default.** Text is read with Apple's Vision framework, and names come from Apple's on-device model or a local Ollama model. Nothing leaves your Mac unless you add a cloud API key yourself.
- **Text only.** With a cloud model, only the extracted text is sent. A small image is sent only if you turn that on.
- **No account, no analytics, no server.** Settings stay on your Mac. A cloud API key is stored in your Keychain.

## AI models

Pick one in **Settings → AI**. **Automatic** uses the first that works:

| Model | What you need | Cost |
|---|---|---|
| **Apple on-device** | macOS 26 with Apple Intelligence turned on | Free |
| **Ollama** | [ollama.com](https://ollama.com), then `ollama pull gemma3:4b` | Free |
| **Cloud API** | Any OpenAI-compatible API and your own key (Anthropic, OpenAI, …) | Your API usage |

If no model answers, the file is named after the app you were using plus the time, e.g. `xcode-2026-11-02-1234.png`.

## Requirements

- macOS 14 Sonoma or later. Apple's on-device model needs macOS 26.
- Built for Apple Silicon.

## FAQ

<details>
<summary><b>Renaming takes a few seconds before anything happens</b></summary>
<br>
macOS doesn't save a screenshot until its floating thumbnail goes away. Turn the thumbnail off: press ⌘⇧5, open Options, and untick Show Floating Thumbnail. Spruce's pill does the same job.
</details>

<details>
<summary><b>Does it work with CleanShot, Shottr and other screenshot apps?</b></summary>
<br>
Yes. Turn on <b>Settings → General → Also match by filename</b>. Those apps don't mark their files as screenshots the way macOS does.
</details>

<details>
<summary><b>What about screenshots I already have?</b></summary>
<br>
Choose <b>Rename Old Screenshots…</b> in the menu bar. You'll see every proposed name first and can edit or skip any of them. The whole batch is one Undo.
</details>

<details>
<summary><b>macOS says Spruce can't be opened</b></summary>
<br>
Spruce isn't notarized by Apple yet. The Terminal install above avoids this. If you downloaded the zip in a browser, open System Settings → Privacy & Security and click <b>Open Anyway</b> next to Spruce.
</details>

<details>
<summary><b>How do I uninstall it?</b></summary>
<br>
Quit Spruce from the menu bar and move <code>/Applications/Spruce.app</code> to the Trash. Your history is in <code>~/Library/Application Support/ScreenshotRenamer</code>.
</details>

## Building from source

<details>
<summary>Build, test and release</summary>

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open ScreenshotRenamer.xcodeproj        # then Run (⌘R)
```

Or from Terminal:

```sh
xcodegen generate
xcodebuild -scheme ScreenshotRenamer -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Spruce.app
```

If `xcode-select` points at the Command Line Tools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The `.xcodeproj` is generated: change targets, Info.plist keys and build settings in `project.yml`.

Self-check for the naming rules:

```sh
swiftc Sources/TextRules.swift Tests/main.swift -o /tmp/selfcheck && /tmp/selfcheck
```

Ship a release (builds, signs the update, updates the feed, publishes on GitHub):

```sh
scripts/release.sh 0.2.0 "What changed"
```

</details>

<details>
<summary>How it works</summary>

| Step | File | What happens |
|---|---|---|
| Watch | `Sources/Watcher.swift` | Watches each folder for files macOS marked as screenshots (`kMDItemIsScreenCapture`, works in every language). |
| Read | `Sources/OCR.swift` | Apple Vision text recognition, on-device. |
| Pick text | `Sources/TextRules.swift` | Drops low-confidence lines and duplicates, ranks the rest by size and position, keeps about 1,500 characters. |
| Name | `Sources/Naming.swift` | Asks the model for a few words, a kind and an optional folder, streamed so the pill can show the name as it's written. |
| Rename | `Sources/Storage.swift` | Spruce, not the model, builds the filename: style, optional date, length limit, safe characters. Existing files are never overwritten. |
| Log | `Sources/Storage.swift` | Each rename is appended to `history.jsonl` and can be undone. |

`Sources/AppState.swift` runs the steps one screenshot at a time. `Sources/Panel.swift` is the pill, `Sources/Manager.swift` the Screenshot Manager, `Sources/Bulk.swift` bulk renaming, and `Sources/Updater.swift` auto-updates (Sparkle, signed with EdDSA).

</details>

---

<div align="center">
<sub>© 2026 gvsh-png. All rights reserved.</sub>
</div>
