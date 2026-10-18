import AgentKit
import Foundation
import TermindApplication

/// The application composes tool-owned policies here, outside the generic renderer.
/// Explicit unknown IDs never fall back to a similarly named local tool.
nonisolated public enum TermindToolPresentationProfiles {
    public static let renderer = AgentToolPresentation(
        profile: profile, vocabulary: TermindToolPresentationVocabulary.vocabulary)

    private static let profiles: [String: AgentToolPresentationProfile] = {
        var profiles: [String: AgentToolPresentationProfile] = [:]
        for presenter in AgentToolCatalog.builtInPresenters {
            var profile = profiles[presenter.id] ?? .init()
            AgentKnowledgeToolPresentation.configure(&profile, presenter: presenter)
            profiles[presenter.id] = profile
        }
        profiles["builtin.web_search"]?.omitsMissingArgumentActivity = true
        for (id, profile) in SSHExecToolPresentation.profiles { profiles[id] = profile }
        for (id, profile) in AgentPaneToolPresentation.profiles { profiles[id] = profile }
        for (id, profile) in AgentChatToolPresentation.profiles { profiles[id] = profile }
        return profiles
    }()

    public static func profile(for descriptor: AgentToolDescriptor) -> AgentToolPresentationProfile {
        if descriptor.target == .mcp {
            var profile = AgentToolPresentationProfile()
            profile.preservesUnprojectedJSON = true
            return profile
        }
        // Privacy is independent of presenter availability; it is not semantic recovery.
        if descriptor.target == .local,
            let privacy = AgentPaneToolPresentation.profiles["builtin.\(descriptor.name)"]
                ?? AgentChatToolPresentation.profiles["builtin.\(descriptor.name)"]
        {
            return privacy
        }
        guard let id = descriptor.presentation?.presenterID else { return .init() }
        return profiles[id] ?? .init()
    }
}
