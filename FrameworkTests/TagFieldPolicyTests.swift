// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Testing

@testable import TermindPresentation

nonisolated private let tagSuggestionCases: [([String], [String], String, [TagFieldPolicy.Row])] = [
    (["production"], ["web", "production", "api"], "", [.existing("web"), .existing("api")]),
    ([], ["api", "web"], " API ", [.existing("api")]),
    ([], ["api", "web"], "PI", [.existing("api"), .create("PI")]),
    ([], ["api"], "   ", [.existing("api")]),
]

@Suite
struct TagFieldPolicyTests {
    @Test(arguments: tagSuggestionCases)
    func suggestionsExcludeSelectedTagsAndOnlyOfferCreateForNewPartialMatches(
        tags: [String], suggestions: [String], query: String, expected: [TagFieldPolicy.Row]
    ) {
        #expect(TagFieldPolicy.rows(tags: tags, suggestions: suggestions, query: query) == expected)
    }

    @Test
    func whitespaceOnlySubmissionIsIgnored() {
        #expect(TagFieldPolicy.submission(query: "   ", suggestions: ["api"]) == nil)
    }

    @Test
    func addingTrimsSpacesPreservesOrderAndRejectsCaseInsensitiveDuplicates() {
        #expect(TagFieldPolicy.adding(" api ", to: ["production"]) == ["production", "api"])
        #expect(TagFieldPolicy.adding(" Production ", to: ["production"]) == ["production"])
        #expect(TagFieldPolicy.adding("\napi\n", to: []) == ["\napi\n"])
    }

    @Test
    func removalIsCaseSensitiveAndSubmissionKeepsTheSuggestionSpelling() {
        #expect(TagFieldPolicy.removing("api", from: ["API", "api", "web"]) == ["API", "web"])
        #expect(TagFieldPolicy.submission(query: " API ", suggestions: ["Api", "web"]) == "Api")
    }
}
