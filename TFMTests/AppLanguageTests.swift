// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

struct AppLanguageTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr"])
    func inputSettingsUseLocalizedShortLabels(language: String) {
        let locale = Locale(identifier: language)
        let title = AppLocalization.resolve(AppStrings.Settings.input, locale: locale)
        let show = AppLocalization.resolve(AppStrings.TerminalInput.show, locale: locale)
        let shortcut = AppLocalization.resolve(AppStrings.Settings.shortcuts, locale: locale)
        #expect(!title.isEmpty && !show.isEmpty && !shortcut.isEmpty)
        if language == "en" {
            #expect(title == "Input" && show == "Show Input Area" && shortcut == "Shortcuts")
        } else {
            #expect(title != "Input" && show != "Show Input Area" && shortcut != "Shortcuts")
        }
    }

    @Test func hostQuotaUsesPaywallWithoutAnErrorMessage() {
        let error: any Error = HostAccessError.hostLimit
        #expect(HostAccessError.presentationDescription(of: error) == nil)
    }

    @Test
    func hostAccessErrorsKeepTheirLocalizedMessageWhenErasedToError() {
        let error: any Error = HostAccessError.entitlementVerificationFailed
        #expect(error.localizedDescription == String(localized: AppStrings.Pro.accessVerificationFailed))
        #expect(
            HostAccessError.presentationDescription(of: error)
                == String(localized: AppStrings.Pro.accessVerificationFailed))
    }

    @Test(arguments: [AppLanguage.korean, .german, .french])
    @MainActor
    func screenshotConversationLocalizesProseWithoutTranslatingTechnicalReferences(language: AppLanguage) {
        let english = ConversationModel.demo(language: .english)
        let localized = ConversationModel.demo(language: language)
        #expect(localized.customTitle != english.customTitle)
        #expect(localized.messages.count == english.messages.count)
        for (message, source) in zip(localized.messages, english.messages) {
            #expect(message.text != source.text)
            #expect(message.role == source.role)
        }
        #expect(localized.messages.last?.text.contains("`127.0.0.1:8080`") == true)
        #expect(localized.messages.last?.text.contains("`/health`") == true)
        #expect(localized.toolCards.map(\.invocation.call.name) == ["ssh_exec_run", "ssh_exec_run"])
    }

    /// Missing and unrecognized preferences fall back to system negotiation
    /// and stay untouched so a later release can still recognize them;
    /// traditional identifiers are not coerced into the simplified catalog.
    @Test(arguments: [nil, "unsupported", "zh-TW", "zh-Hant-TW", "zh-HK", "zh-MO"] as [String?])
    func missingAndUnknownPreferencesFollowSystem(identifier: String?) throws {
        let defaults = try makeDefaults()
        if let identifier { defaults.set(identifier, forKey: SettingsKey.appLanguage) }

        #expect(AppLanguage.stored(in: defaults) == .system)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == identifier)
    }

    @Test(arguments: ["zh-Hans-CN", "zh-CN", "zh_CN", "zh-Hans-SG", "zh"])
    func legacySimplifiedChinesePreferencesMigrateToCanonicalTag(identifier: String) throws {
        let defaults = try makeDefaults()
        defaults.set(identifier, forKey: SettingsKey.appLanguage)
        defaults.set([identifier], forKey: "AppleLanguages")

        #expect(AppLanguage.stored(in: defaults) == .simplifiedChinese)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "zh-Hans")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
    }

    @Test
    func traditionalChineseDisplayNameRequiresTaiwanRegionAndVisibleFlag() {
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: "TW", canDisplayTaiwanFlag: true)
                == "正體中文")
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: "TW", canDisplayTaiwanFlag: false)
                == "繁體中文")
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: "HK", canDisplayTaiwanFlag: true)
                == "繁體中文")
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: nil, canDisplayTaiwanFlag: false)
                == "繁體中文")
        #expect(AppLanguage.english.displayName(deviceRegion: "TW", canDisplayTaiwanFlag: true) == "English")
    }

    @Test(arguments: ["Google", "OpenAI", "사용자 모델"])
    func koreanDynamicLabelsDoNotAssumeTheFinalConsonantOfAProviderName(provider: String) {
        let locale = Locale(identifier: "ko")
        #expect(
            AppLocalization.resolve(
                AppStrings.Assistant.modelHelp(modelName: "model-01", providerName: provider, effortName: nil),
                locale: locale
            ) == "model-01 · 제공업체: \(provider)")
        #expect(
            AppLocalization.resolve(
                AppStrings.Assistant.modelHelp(modelName: "model-01", providerName: provider, effortName: "높음"),
                locale: locale
            ) == "model-01 · 제공업체: \(provider) · 추론 강도: 높음")
        #expect(
            AppLocalization.resolve(
                AppStrings.Assistant.compactionSummary(summarized: "2,000 토큰", retained: "500 토큰"),
                locale: locale
            ) == "압축됨 — 2,000 토큰 → 500 토큰")
    }

    @Test
    func taiwanFlagColorDetectionHandlesColorGrayscaleAndMissingPixels() {
        #expect(DeviceCensorship.containsColoredPixel([255, 0, 0, 255]))
        #expect(!DeviceCensorship.containsColoredPixel([128, 128, 128, 255]))
        #expect(!DeviceCensorship.containsColoredPixel([]))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
