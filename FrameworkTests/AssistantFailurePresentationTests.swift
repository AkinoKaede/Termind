// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindPresentation
import Testing

@Suite @MainActor
struct AssistantFailurePresentationTests {
    @Test func endpointFailureUsesTheRemoteMessageInsteadOfTheJSONEnvelope() {
        let reason =
            #"The model endpoint returned 400: {"error":{"message":"Missing required parameter: 'tools[48].description'.","code":"invalid_request_body"}}"#
        #expect(
            AssistantFailurePresentation.summary(for: reason) == "Missing required parameter: 'tools[48].description'.")
    }

    @Test(arguments: [
        (#"{"message":"Request timed out"}"#, "Request timed out"),
        (#"{"error":"Permission denied"}"#, "Permission denied"),
        (#"{"error":{"message":"  Rate limit\nexceeded  "}}"#, "Rate limit exceeded"),
        ("Connection refused\nAdditional diagnostics", "Connection refused"),
        (#"The endpoint returned 500: {"broken"#, "The endpoint returned 500:"),
        (#"The endpoint returned 503: {"error":{"code":123}}"#, "The endpoint returned 503:"),
    ])
    func summariesHandleDifferentErrorShapes(_ reason: String, _ expected: String) {
        #expect(AssistantFailurePresentation.summary(for: reason) == expected)
    }

    @Test func emptyDiagnosticUsesLocalizedFallbackAndLongMessagesAreBounded() {
        #expect(
            AssistantFailurePresentation.summary(for: " \n\t ")
                == String(localized: AppStrings.Assistant.agentError))
        let message = String(repeating: "A", count: 200)
        #expect(AssistantFailurePresentation.summary(for: message) == String(repeating: "A", count: 159) + "\u{2026}")
    }
}
