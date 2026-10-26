// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum TerminalInput {
        public static var show: LocalizedStringResource { "Show Input Area" }
        public static var hide: LocalizedStringResource { "Hide Input Area" }
        public static var title: LocalizedStringResource { "Terminal Input Area" }
        public static var generator: LocalizedStringResource { "Generator" }
        public static var inputPrompt: LocalizedStringResource { "Enter text to send to the terminal..." }
        public static var generationPrompt: LocalizedStringResource { "Describe the command you want to generate..." }
        public static var mode: LocalizedStringResource { "Input Mode" }
        public static var resize: LocalizedStringResource { "Resize Input Area" }
        public static var unavailable: LocalizedStringResource {
            "Input could not be sent. Check that every target terminal is connected and ready."
        }
        public static var generatorRequiresSSH: LocalizedStringResource {
            "Command generation in the input area requires a connected SSH terminal."
        }
    }
}
