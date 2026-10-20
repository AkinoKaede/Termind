// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication

/// A user-initiated store link, also used by the permanent Settings entry.
public struct AppReviewLink<Label: View>: View {
    @Environment(\.openURL) private var openURL
    private let controller: AppReviewController?
    private let label: Label

    public init(controller: AppReviewController?, @ViewBuilder label: () -> Label) {
        self.controller = controller
        self.label = label()
    }

    public var body: some View {
        Button {
            if let controller {
                controller.openReview { url, completion in
                    openURL(url, completion: completion)
                }
            } else {
                openURL(AppReviewController.reviewURL)
            }
        } label: {
            label
        }
    }
}

public struct AppReviewInvitationView: View {
    private let controller: AppReviewController

    public init(controller: AppReviewController) {
        self.controller = controller
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                message
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                message
                actions
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.invitation")
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppStrings.AppReview.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(AppStrings.AppReview.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                accept
                decline
            }
            VStack(alignment: .leading, spacing: 8) {
                accept
                decline
            }
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accept: some View {
        AppReviewLink(controller: controller) {
            Text(AppStrings.AppReview.accept)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityHint(Text(AppStrings.Settings.rateOnTheAppStore))
        .accessibilityIdentifier("review.accept")
    }

    private var decline: some View {
        Button(action: controller.decline) {
            Text(AppStrings.AppReview.decline)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("review.decline")
    }
}
