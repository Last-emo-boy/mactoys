import Foundation

/// Where Paste with AI sends requests: any OpenAI-compatible chat-completions endpoint.
/// The API key lives in the Keychain under `keychainAccount`, never in settings JSON.
public struct AIProvider: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case openAI, azureOpenAI, ollama, compatible
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .openAI: "OpenAI"
            case .azureOpenAI: "Azure OpenAI"
            case .ollama: "Ollama (local)"
            case .compatible: "OpenAI-compatible endpoint"
            }
        }

        public var isLocal: Bool { self == .ollama }
    }

    public var kind: Kind
    /// Base URL: `https://api.openai.com/v1`, `https://<resource>.openai.azure.com`, `http://localhost:11434/v1`.
    public var endpoint: String
    /// Model name; for Azure OpenAI the deployment name.
    public var model: String
    /// Azure OpenAI only.
    public var apiVersion: String
    /// Replaces the built-in instructions when not empty.
    public var systemPrompt: String

    public init(kind: Kind, endpoint: String, model: String, apiVersion: String = "", systemPrompt: String = "") {
        self.kind = kind
        self.endpoint = endpoint
        self.model = model
        self.apiVersion = apiVersion
        self.systemPrompt = systemPrompt
    }

    public static func preset(_ kind: Kind) -> AIProvider {
        switch kind {
        case .openAI: AIProvider(kind: kind, endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini")
        case .azureOpenAI: AIProvider(kind: kind, endpoint: "https://YOUR-RESOURCE.openai.azure.com", model: "gpt-4o-mini",
                                      apiVersion: "2024-10-21")
        case .ollama: AIProvider(kind: kind, endpoint: "http://localhost:11434/v1", model: "llama3.2")
        case .compatible: AIProvider(kind: kind, endpoint: "https://", model: "")
        }
    }

    /// Keychain account holding this provider kind's API key.
    public var keychainAccount: String { "advancedpaste.apikey.\(kind.rawValue)" }
    /// Local servers usually need no key.
    public var requiresKey: Bool { kind == .openAI || kind == .azureOpenAI }

    public static let defaultSystemPrompt = """
        You are tasked with reformatting the user's clipboard data. Follow the user's instructions and apply them \
        to the clipboard content. Output only the transformed content, without explanations, quotes or code fences \
        unless the instructions ask for them.
        """
}

public enum AIError: LocalizedError, Equatable {
    case notConfigured(String)
    case missingKey
    case server(status: Int, message: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what): "Paste with AI isn't set up: \(what)."
        case .missingKey: "Add an API key for the AI provider in Advanced Paste settings."
        case .server(let status, let message):
            switch status {
            case 401, 403: "The AI provider rejected the API key (\(status)). \(message)"
            case 429: "The AI provider's quota or rate limit was exceeded. \(message)"
            default: "The AI provider returned an error (\(status)). \(message)"
            }
        case .emptyResponse: "The AI provider returned no text."
        }
    }
}

/// OpenAI chat-completions client (also Azure OpenAI's deployment URLs and local servers).
public enum AIClient {
    /// Builds the HTTP request; pure so it can be tested.
    public static func request(provider: AIProvider, apiKey: String?, instructions: String, content: String) throws -> URLRequest {
        var base = provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, base != "https:", base != "http:" else { throw AIError.notConfigured("no endpoint URL") }
        if provider.requiresKey && (apiKey ?? "").isEmpty { throw AIError.missingKey }

        let urlString: String
        switch provider.kind {
        case .azureOpenAI:
            guard !provider.model.isEmpty else { throw AIError.notConfigured("no deployment name") }
            let deployment = provider.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? provider.model
            let version = provider.apiVersion.isEmpty ? "2024-10-21" : provider.apiVersion
            urlString = base.hasSuffix("/chat/completions") ? base
                : "\(base)/openai/deployments/\(deployment)/chat/completions?api-version=\(version)"
        default:
            guard !provider.model.isEmpty else { throw AIError.notConfigured("no model name") }
            urlString = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        }
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            throw AIError.notConfigured("the endpoint URL is invalid")
        }

        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            if provider.kind == .azureOpenAI {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        let system = provider.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AIProvider.defaultSystemPrompt : provider.systemPrompt
        let user = "Instructions:\n\(instructions)\n\nClipboard content:\n\(content)"
        var body: [String: Any] = ["messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        if provider.kind != .azureOpenAI { body["model"] = provider.model }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Extracts the reply text, or the provider's error message.
    public static func parse(_ data: Data, status: Int) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            var message = ""
            if let error = object?["error"] as? [String: Any] { message = error["message"] as? String ?? "" }
            else if let error = object?["error"] as? String { message = error }
            else if let m = object?["message"] as? String { message = m }
            else { message = String(decoding: data.prefix(300), as: UTF8.self) }
            throw AIError.server(status: status, message: message)
        }
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        var text: String?
        if let s = message?["content"] as? String {
            text = s
        } else if let parts = message?["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func complete(provider: AIProvider, apiKey: String?, instructions: String, content: String) async throws -> String {
        let request = try request(provider: provider, apiKey: apiKey, instructions: instructions, content: content)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
