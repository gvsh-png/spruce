import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Step 3 of the pipeline: ask a model for words that describe the screenshot.
///
/// Two ways to reach a model:
/// - Apple's on-device model (macOS 26 with Apple Intelligence; compiled only with the macOS 26 SDK).
/// - Any OpenAI-compatible chat endpoint. That one client covers Ollama, LM Studio,
///   OpenAI, OpenRouter and Anthropic, which differ only in base URL, model and key.

enum ProviderMode: String, Codable, CaseIterable, Identifiable {
    case auto, apple, ollama, cloud
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .apple: "Apple on-device"
        case .ollama: "Ollama (local)"
        case .cloud: "Cloud API"
        }
    }
}

struct NamingInput {
    var text: String
    /// Small JPEG, present only when OCR found almost no text.
    var image: Data?
}

enum NamingError: LocalizedError {
    case noProvider
    case network(URLError)
    case http(Int, String)
    case badReply(String)
    case badURL(String)
    /// Nothing to name from: no text, and the chosen model can't see images.
    case noText

    var errorDescription: String? {
        switch self {
        case .noProvider: "No AI model is available. Turn on Apple Intelligence, start Ollama, or add a cloud API key in Settings."
        case .network(let e): "Network error: \(e.localizedDescription)"
        case .http(let code, let body): "The AI service answered \(code): \(body)"
        case .badReply: "The model's reply had no usable name."
        case .badURL(let s): "“\(s)” is not a valid server address. Fix it in Settings → AI."
        case .noText: "No text found."
        }
    }

    /// Worth trying again after a pause: connection trouble, rate limits, server errors, malformed JSON.
    var isRetryable: Bool {
        switch self {
        case .network, .badReply: true
        case .http(let code, _): code == 429 || code >= 500
        case .noProvider, .badURL, .noText: false
        }
    }
}

struct Namer {
    var prefs: Preferences
    var apiKey: String?

    /// Returns the suggestion and a label for the provider that produced it (kept in history).
    /// `onPartial` receives the words so far while Apple's model is still writing (streaming).
    func suggest(_ input: NamingInput, onPartial: (([String]) -> Void)? = nil) async throws -> (Suggestion, String) {
        let system = Prompt.system(folders: prefs.sortingEnabled ? prefs.folders : [])
        switch prefs.provider {
        case .apple:
            return (try await apple(input, system: system, onPartial: onPartial), "apple")
        case .ollama:
            return (try await chat(prefs.ollamaURL, prefs.ollamaModel, key: nil, input, system), "ollama:\(prefs.ollamaModel)")
        case .cloud:
            return (try await cloud(input, system), "cloud:\(prefs.cloudModel)")
        case .auto:
            // Apple can't see images: when the text is thin and an image exists, try Ollama first.
            let preferImage = input.image != nil
            if Self.appleAvailable && !preferImage {
                return (try await apple(input, system: system, onPartial: onPartial), "apple")
            }
            if await reachable(prefs.ollamaURL) {
                do {
                    return (try await chat(prefs.ollamaURL, prefs.ollamaModel, key: nil, input, system), "ollama:\(prefs.ollamaModel)")
                } catch NamingError.http(404, _) {
                    // Ollama runs but the model isn't pulled: try the next provider.
                }
            }
            if Self.appleAvailable {
                return (try await apple(input, system: system, onPartial: onPartial), "apple")
            }
            // Cloud only when the user added a key: that is the explicit opt-in.
            if let apiKey, !apiKey.isEmpty {
                return (try await cloud(input, system), "cloud:\(prefs.cloudModel)")
            }
            throw NamingError.noProvider
        }
    }

    private func cloud(_ input: NamingInput, _ system: String) async throws -> Suggestion {
        guard let apiKey, !apiKey.isEmpty else { throw NamingError.noProvider }
        var input = input
        if !prefs.allowCloudImages { input.image = nil } // images leave the Mac only with explicit permission
        return try await chat(prefs.cloudURL, prefs.cloudModel, key: apiKey, input, system)
    }

    // MARK: Apple on-device model

    /// Loads Apple's model into memory ahead of time, so the first rename doesn't pay the load cost.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), appleAvailable { LanguageModelSession().prewarm() }
        #endif
    }

    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private func apple(_ input: NamingInput, system: String, onPartial: (([String]) -> Void)?) async throws -> Suggestion {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard Self.appleAvailable else { throw NamingError.noProvider }
            guard !input.text.isEmpty else { throw NamingError.noText } // text-only model: use the fallback name
            let session = LanguageModelSession(instructions: system)
            let prompt = Prompt.user(text: input.text, hasImage: false)
            // Guided generation: the model must fill this struct, so there is no JSON to parse.
            // Streamed, so the island can show the name as it's written (first words in ~1 s).
            var last: GeneratedName.PartiallyGenerated?
            for try await snapshot in session.streamResponse(to: prompt, generating: GeneratedName.self) {
                last = snapshot.content
                if let words = snapshot.content.words { onPartial?(words) }
            }
            let words = last?.words ?? []
            let folder = (last?.folder ?? "").trimmingCharacters(in: .whitespaces)
            return Suggestion(words: words, folder: folder.isEmpty || folder == "null" ? nil : folder, kind: last?.kind)
        }
        #endif
        throw NamingError.noProvider
    }

    // MARK: OpenAI-compatible chat endpoint

    private func chat(_ base: String, _ model: String, key: String?, _ input: NamingInput, _ system: String) async throws -> Suggestion {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true
        else { throw NamingError.badURL(base) }
        // Never send an API key in the clear, except to a server on this Mac.
        if key != nil, url.scheme != "https", !["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") {
            throw NamingError.badURL(base)
        }

        let text = Prompt.user(text: input.text, hasImage: input.image != nil)
        let userContent: Any = input.image.map { image in
            [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
            ]
        } ?? text
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 400,
            "messages": [["role": "system", "content": system], ["role": "user", "content": userContent]],
        ]

        var request = URLRequest(url: url.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        var data = Data(), status = 0
        for attempt in 0..<2 {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let response: URLResponse
            do { (data, response) = try await URLSession.shared.data(for: request) }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as URLError { throw NamingError.network(error) }
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Reasoning models (OpenAI o-series, GPT-5) reject `max_tokens` and custom temperatures:
            // ask once more with only the required fields.
            guard status == 400, attempt == 0 else { break }
            body["temperature"] = nil
            body["max_tokens"] = nil
        }
        guard status == 200 else { throw NamingError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }

        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }
            var choices: [Choice]
        }
        let content = (try? JSONDecoder().decode(Reply.self, from: data))?.choices.first?.message.content ?? ""
        guard let suggestion = TextRules.parseSuggestion(content) else { throw NamingError.badReply(content) }
        return suggestion
    }

    /// Quick check whether a local server (Ollama) is running.
    private func reachable(_ base: String) async -> Bool {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces))?.appendingPathComponent("models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let response = try? await URLSession.shared.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct GeneratedName {
    @Guide(description: "3 to 7 words: the app or website first if the text shows it, then people, project or topic")
    var words: [String]
    @Guide(description: "The best-fitting folder from the allowed list; empty only when none fits")
    var folder: String
    @Guide(description: "What kind of screenshot this is", .anyOf(TextRules.kinds))
    var kind: String
}
#endif
