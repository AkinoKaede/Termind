import Foundation

/// Asks one model to say something, and reports whether it did.
///
/// This is what the Test button runs, and it is deliberately a *chat* request
/// rather than a call to `/models`. Listing models proves the base URL and the
/// key; it says nothing about whether the API path is right, whether the
/// Responses toggle matches what the endpoint serves, or whether this
/// particular model id is one the account may actually call. Those are the
/// three things that break, and only a real request finds them.
///
/// It is also the smallest honest version of the request P3 will build for the
/// conversation. When streaming lands, the body writers below are what it grows
/// from — which is why they are shaped per provider kind rather than hidden
/// behind one lowest-common-denominator struct.
nonisolated struct ChatProbe: Sendable {
    /// Short enough to cost almost nothing, explicit enough that a model which
    /// answers at all answers quickly.
    static let prompt = "Reply with OK."

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Longer than the catalog client's: a reasoning model can take a
            // few seconds to answer even this, and timing it out would report a
            // working setup as broken.
            self.session = ProviderNetworking.session(timeout: 60)
        }
    }

    /// What one model said, and how long it took.
    nonisolated struct Result: Sendable {
        /// The first of the reply, when the response carried text. Empty when
        /// the model answered but said nothing extractable — a reasoning model
        /// that spent its budget thinking, say. Still a pass: the request was
        /// accepted and billed, which is the question being asked.
        var reply: String
        var milliseconds: Int

        var summary: String {
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return String(localized: "Answered in \(milliseconds) ms") }
            return "\(trimmed.prefix(40)) · \(milliseconds) ms"
        }
    }

    func run(model: AIModel, on provider: ModelProvider, secret: String) async throws -> Result {
        let url = try Self.url(for: model, on: provider)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.body(for: model, on: provider)
        try await ProviderNetworking.authorize(
            &request, provider: provider, secret: secret
        )

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ModelCatalogError.transport(error.localizedDescription)
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.transport(String(localized: "The endpoint did not answer with HTTP."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelCatalogError(status: http.statusCode, body: data)
        }

        return Result(reply: Self.reply(in: data), milliseconds: elapsed)
    }

    // MARK: - Where

    private static func url(for model: AIModel, on provider: ModelProvider) throws -> URL {
        let resolved = provider.resolvedRequestURL(model: model.id)
        guard let url = URL(string: resolved) else { throw ModelCatalogError.badURL(resolved) }
        return url
    }

    // MARK: - What

    static func body(for model: AIModel, on provider: ModelProvider) throws -> Data {
        let object: [String: Any]

        switch provider.kind {
        case .openAI where provider.usesResponsesAPI:
            // The Responses API accepts a bare string, but compatible gateways
            // are not uniformly permissive: some require `input` to be the
            // canonical list of input items. The list form works with OpenAI as
            // well, so use it for the probe rather than making a valid setup
            // look broken behind one of those gateways.
            object = [
                "model": model.id,
                "input": [
                    [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": prompt]],
                    ]
                ],
            ]

        case .openAI:
            // No output cap. `max_tokens` and `max_completion_tokens` are not
            // interchangeable across OpenAI's own model generations, and sending
            // the wrong one is a 400 that would read as "this model is broken".
            // The prompt is two words; there is nothing to cap.
            object = [
                "model": model.id,
                "messages": [["role": "user", "content": prompt]],
            ]

        case .anthropic:
            // `max_tokens` is required here, unlike everywhere else. Generous
            // rather than minimal: a thinking model given 16 tokens spends them
            // all before it starts answering.
            object = [
                "model": model.id,
                "max_tokens": 64,
                "messages": [["role": "user", "content": prompt]],
            ]

        case .google:
            // The model is named in the URL, not the body.
            object = ["contents": [["role": "user", "parts": [["text": prompt]]]]]
        }

        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Pulls the reply out of whichever envelope came back.
    ///
    /// Deliberately forgiving: this is a liveness check, and a 200 has already
    /// answered the question. Text is a bonus that makes the result readable —
    /// so every path returns `""` rather than throwing when the shape is not one
    /// of the four below.
    private static func reply(in data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

        // OpenAI chat completions.
        if let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        {
            return content
        }

        // OpenAI Responses — the convenience field first, then the long form.
        if let text = root["output_text"] as? String { return text }
        if let output = root["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let text = part["text"] as? String { return text }
                }
            }
        }

        // Anthropic messages.
        if let content = root["content"] as? [[String: Any]] {
            for block in content {
                if let text = block["text"] as? String, !text.isEmpty { return text }
            }
        }

        // Google generateContent.
        if let candidates = root["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        {
            for part in parts {
                if let text = part["text"] as? String { return text }
            }
        }

        return ""
    }
}
