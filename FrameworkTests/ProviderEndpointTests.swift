// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

/// The rule that turns one typed address and one picked API type into a
/// request URL, a body format, and a models listing.
@Suite
@MainActor
struct ProviderEndpointTests {
    /// The four cases the picker has to get right, read back the way the editor
    /// reads them: what was typed stays what is shown, and the composed address
    /// is what a request uses.
    @Test
    func automaticReadsTheFormatOffTheURLAndFallsBackToChatCompletions() {
        let cases: [(url: String, format: ModelAPIFormat, request: String)] = [
            // No endpoint named — Chat Completions, and the path is appended.
            (
                "https://x.test/v1", .chatCompletions,
                "https://x.test/v1/chat/completions"
            ),
            // Named, so the address is used exactly as it was typed.
            ("https://x.test/v1/chat/completions", .chatCompletions, "https://x.test/v1/chat/completions"),
            ("https://x.test/v1/responses", .responses, "https://x.test/v1/responses"),
            ("https://x.test/v1/messages", .messages, "https://x.test/v1/messages"),
            (
                "https://x.test/v1beta/models/{model}:generateContent", .generateContent,
                "https://x.test/v1beta/models/{model}:generateContent"
            ),
            // A gateway is free to serve a shape under a prefix of its own.
            (
                "https://x.test/anthropic/v1/messages", .messages,
                "https://x.test/anthropic/v1/messages"
            ),
        ]

        for entry in cases {
            let endpoint = ProviderEndpoint(url: entry.url)
            #expect(endpoint.format == entry.format, "format for \(entry.url)")
            #expect(endpoint.requestURL == entry.request, "request URL for \(entry.url)")
            // What was typed is what the field shows again.
            #expect(endpoint.url == entry.url)
        }
    }

    /// The three differences that are never meaningful in an endpoint name and
    /// are all present in URLs people paste.
    @Test
    func detectionIgnoresCaseTrailingSlashesAndQueries() {
        #expect(ProviderEndpoint(url: "https://x.test/v1/MESSAGES").format == .messages)
        #expect(ProviderEndpoint(url: "https://x.test/v1/messages/").format == .messages)
        #expect(ProviderEndpoint(url: "https://x.test/v1/messages?beta=1").format == .messages)

        // Streaming is the same endpoint with the same body, so someone who
        // pasted that variant has still said which shape they meant.
        #expect(
            ProviderEndpoint(url: "https://x.test/v1beta/models/g-1:streamGenerateContent").format
                == .generateContent
        )
    }

    /// A query has to survive, and it has to stay at the end — appending a path
    /// behind `?key=…` would make the key part of the path.
    @Test
    func aQueryStaysAtTheEndOfWhateverIsComposed() {
        let endpoint = ProviderEndpoint(url: "https://x.test/v1?key=abc")
        #expect(endpoint.requestURL == "https://x.test/v1/chat/completions?key=abc")
        #expect(endpoint.baseURL == "https://x.test/v1?key=abc")
    }

    /// An explicit pick changes the body and not the destination.
    ///
    /// Rewriting the address to match the picked type would overrule the person
    /// who pasted it; the caption under the field says which format is going
    /// there instead.
    @Test
    func anExplicitTypeOverridesTheURLWithoutMovingIt() {
        let conflicting = ProviderEndpoint(
            apiType: .messages, url: "https://x.test/v1/chat/completions"
        )
        #expect(conflicting.format == .messages)
        #expect(conflicting.requestURL == "https://x.test/v1/chat/completions")

        // And an explicit pick on a bare base URL supplies that format's path.
        let bare = ProviderEndpoint(apiType: .generateContent, url: "https://x.test/v1beta")
        #expect(bare.requestURL == "https://x.test/v1beta/models/{model}:generateContent")
    }

    /// The base a listing hangs off is the typed URL with the endpoint removed.
    ///
    /// The `generateContent` shape is why this cannot be a fixed suffix: it
    /// names the model inside the path, so cutting at the colon would leave the
    /// model id behind and AgentKit would list from `…/models/gemini-x/models`.
    @Test
    func theListingBaseHasTheEndpointRemoved() {
        let cases = [
            ("https://x.test/v1/chat/completions", "https://x.test/v1"),
            ("https://x.test/v1", "https://x.test/v1"),
            ("https://x.test/v1beta/models/gemini-x:generateContent", "https://x.test/v1beta"),
            ("https://x.test/anthropic/v1/messages", "https://x.test/anthropic/v1"),
        ]
        for (typed, base) in cases {
            #expect(ProviderEndpoint(url: typed).baseURL == base, "base for \(typed)")
        }
        #expect(ProviderEndpoint(url: "  ").baseURL.isEmpty)

        // And the half AgentKit owns: `/models` appended to that base.
        var provider = ModelProvider(name: "Gateway")
        provider.baseURL = ProviderEndpoint(url: "https://x.test/v1/chat/completions").baseURL
        #expect(provider.resolvedModelsURL == "https://x.test/v1/models")
    }

    /// A provider nobody has typed an address into points nowhere, and says so
    /// rather than reaching some vendor's public endpoint.
    @Test
    func aBlankURLComposesNothing() {
        let endpoint = ProviderEndpoint()
        #expect(!endpoint.isConfigured)
        #expect(endpoint.requestURL.isEmpty)
        #expect(endpoint.baseURL.isEmpty)
    }

    /// Every pre-V12 combination read back as the endpoint it resolved to.
    ///
    /// The old shape had two fields and two fallbacks — a blank base URL meant
    /// the vendor's public host, a blank path meant that vendor's default
    /// endpoint — and both are gone. What this pins is that a provider which
    /// worked before the change still points at the same address after it.
    @Test
    func legacyRowsFoldIntoTheAddressTheyUsedToResolveTo() {
        let cases: [(kind: String, responses: Bool, format: ModelAPIFormat, url: String)] = [
            ("openAI", false, .chatCompletions, "https://api.openai.com/v1/chat/completions"),
            ("openAI", true, .responses, "https://api.openai.com/v1/responses"),
            ("anthropic", false, .messages, "https://api.anthropic.com/v1/messages"),
            (
                "google", false, .generateContent,
                "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
            ),
        ]

        for entry in cases {
            let row = PersistentModelProvider(
                ModelProvider(name: "Legacy"), endpoint: ProviderEndpoint(), sortIndex: 0
            )
            row.apiType = ""
            row.kind = entry.kind
            row.usesResponsesAPI = entry.responses

            #expect(row.endpoint.format == entry.format, "format for \(entry.kind)")
            #expect(row.value(models: []).inferenceURL == entry.url, "URL for \(entry.kind)")
            // Explicit rather than Automatic: reproducing the old behaviour
            // beats re-deriving it and hoping the two agree.
            #expect(row.endpoint.apiType == ModelAPIType(entry.format))
        }
    }

    /// A base URL and an API path the user actually typed are kept, rather than
    /// replaced by the format's default path.
    @Test
    func legacyRowsKeepATypedBaseAndPath() {
        let row = PersistentModelProvider(
            ModelProvider(name: "Legacy"), endpoint: ProviderEndpoint(), sortIndex: 0
        )
        row.apiType = ""
        row.kind = "anthropic"
        row.baseURL = "https://gateway.test/anthropic"
        row.apiPath = "/v1/messages"

        #expect(row.endpoint.url == "https://gateway.test/anthropic/v1/messages")
        #expect(row.value(models: []).inferenceURL == "https://gateway.test/anthropic/v1/messages")
        #expect(row.value(models: []).apiFormat == .messages)
    }

}
