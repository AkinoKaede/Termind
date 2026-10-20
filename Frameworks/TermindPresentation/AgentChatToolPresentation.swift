// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

/// Chat bodies are never a fallback for missing or failed compact projections.
nonisolated enum AgentChatToolPresentation {
    static let profiles: [String: AgentToolPresentationProfile] = Dictionary(
        uniqueKeysWithValues: [
            "list_models", "create_new_chat", "list_chats", "read_chat", "send_to_chat", "wait_chats",
        ].map { ("builtin.\($0)", profile) })

    private static var profile: AgentToolPresentationProfile {
        var profile = AgentToolPresentationProfile()
        profile.requiresArgumentProjection = true
        profile.detail = { card, presenter, locale in
            guard let result = card.result else { return .hidden }
            let fallback = AgentToolPresentationProfile.Detail.content(
                .init(items: [
                    .message(
                        AppLocalization.resolve(AppStrings.Assistant.chatDetailsUnavailable, locale: locale),
                        result.isError ? .failure : .secondary)
                ]))
            if result.isError || card.state == .failed || card.state == .denied || card.state == .interrupted {
                guard
                    AgentToolPresentation().detailOutput(
                        from: result, presentation: card.descriptor.presentation, review: card.review) != nil
                else { return .hidden }
                return fallback
            }
            let raw = result.untrustedPayload ?? result.content
            guard let value = try? AgentJSONValue.decode(Data(raw.utf8)), let presenter else { return fallback }
            return .content(
                .init(
                    items: presenter.present(
                        .init(
                            result: value, arguments: card.invocation.call.arguments.objectValue ?? [:], locale: locale)
                    )))
        }
        return profile
    }
}
