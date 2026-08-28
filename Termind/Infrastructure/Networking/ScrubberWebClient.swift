import Foundation
import ScrubberKit

nonisolated struct ScrubbedWebDocument: Hashable, Sendable {
    var engine: String? = nil
    var title: String
    var url: URL
    var markdown: String
    var original: String
}

nonisolated enum ScrubberWebError: LocalizedError, Sendable {
    case invalidURL
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The webpage URL must be an HTTP or HTTPS URL without embedded credentials."
        case .emptyDocument:
            "No readable content could be extracted from the webpage."
        }
    }
}

/// The one bridge from Termind's async tools to ScrubberKit's callback API.
///
/// The injectable closures keep tool tests deterministic without replacing the
/// package or reaching the public web. The live implementation remains
/// MainActor-isolated because ScrubberKit owns WKWebView instances internally.
nonisolated struct ScrubberWebClient: Sendable {
    typealias DocumentLoader = @Sendable (URL) async throws -> ScrubbedWebDocument
    typealias SearchLoader = @Sendable (String, Int) async throws -> [ScrubbedWebDocument]

    private let documentLoader: DocumentLoader
    private let searchLoader: SearchLoader

    init() {
        documentLoader = { try await Self.loadDocument($0) }
        searchLoader = { try await Self.runSearch(query: $0, count: $1) }
    }

    init(document: @escaping DocumentLoader, search: @escaping SearchLoader) {
        documentLoader = document
        searchLoader = search
    }

    @MainActor
    static func setup() {
        ScrubberConfiguration.setup()
    }

    func document(for rawURL: String) async throws -> ScrubbedWebDocument {
        let url = try Self.validatedURL(rawURL)
        try Task.checkCancellation()
        let document = try await documentLoader(url)
        try Task.checkCancellation()
        return document
    }

    func search(_ query: String, count: Int) async throws -> [ScrubbedWebDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.invalidArguments("query is required.")
        }
        try Task.checkCancellation()
        let documents = try await searchLoader(trimmed, count)
        try Task.checkCancellation()
        return documents
    }

    static func validatedURL(_ rawURL: String) throws -> URL {
        guard let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { throw ScrubberWebError.invalidURL }
        return url
    }

    @MainActor
    private static func loadDocument(_ url: URL) async throws -> ScrubbedWebDocument {
        let document: Scrubber.Document? = await withCheckedContinuation { continuation in
            Scrubber.document(for: url) { continuation.resume(returning: $0) }
        }
        guard let document else { throw ScrubberWebError.emptyDocument }
        return ScrubbedWebDocument(
            engine: document.engine?.rawValue,
            title: document.title,
            url: document.url,
            markdown: document.markdownDocument,
            original: document.document
        )
    }

    @MainActor
    private static func runSearch(query: String, count: Int) async throws
        -> [ScrubbedWebDocument]
    {
        let scrubber = Scrubber(
            query: query,
            options: .init(urlsReranker: URLsReranker(question: query))
        )
        return await withTaskCancellationHandler {
            let documents: [Scrubber.Document] = await withCheckedContinuation { continuation in
                scrubber.run(limitation: count) { continuation.resume(returning: $0) }
            }
            return documents.prefix(count).map {
                ScrubbedWebDocument(
                    engine: $0.engine?.rawValue,
                    title: $0.title,
                    url: $0.url,
                    markdown: $0.markdownDocument,
                    original: $0.document
                )
            }
        } onCancel: {
            Task { @MainActor in scrubber.cancel() }
        }
    }
}
