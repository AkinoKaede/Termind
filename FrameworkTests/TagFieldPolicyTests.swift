import SwiftUI
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

@Suite
struct TagFlowGeometryTests {
    @Test
    func emptyContentHasZeroHeight() {
        #expect(TagFlowGeometry.size(sizes: [], width: 100, spacing: 6) == CGSize(width: 100, height: 0))
    }

    @Test
    func finiteWidthWrapsButExactBoundaryDoesNot() {
        let sizes = [CGSize(width: 4, height: 10), CGSize(width: 4, height: 20)]
        #expect(TagFlowGeometry.rows(sizes: sizes, width: 10, spacing: 2).map(\.indices) == [[0, 1]])
        #expect(TagFlowGeometry.rows(sizes: sizes, width: 9, spacing: 2).map(\.indices) == [[0], [1]])
    }

    @Test
    func oversizedFirstChipIsKeptAndVariableRowHeightsAreSummed() {
        let sizes = [
            CGSize(width: 12, height: 7),
            CGSize(width: 4, height: 11),
            CGSize(width: 4, height: 5),
        ]
        let rows = TagFlowGeometry.rows(sizes: sizes, width: 10, spacing: 2)
        #expect(rows.map(\.indices) == [[0], [1, 2]])
        #expect(TagFlowGeometry.size(sizes: sizes, width: 10, spacing: 2).height == 20)
    }

    @Test
    func unspecifiedWidthRetainsEachPlatformsSizingPolicy() {
        let proposal = ProposedViewSize(width: nil, height: nil)
        #expect(TagFlowGeometry.width(proposal: proposal, naturalWidth: 42, sizing: .proposed) == 10)
        #expect(TagFlowGeometry.width(proposal: proposal, naturalWidth: 42, sizing: .intrinsic) == 42)
    }

    @Test
    func intrinsicSizingHandlesNonFiniteAndNegativeProposals() {
        #expect(
            TagFlowGeometry.width(
                proposal: ProposedViewSize(width: .infinity, height: nil), naturalWidth: 42, sizing: .intrinsic
            ) == 42
        )
        #expect(
            TagFlowGeometry.width(
                proposal: ProposedViewSize(width: -5, height: nil), naturalWidth: 42, sizing: .intrinsic
            ) == 0
        )
    }
}
