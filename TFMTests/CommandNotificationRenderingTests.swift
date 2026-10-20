// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct CommandNotificationRenderingTests {
    @Test func transfersNotificationOpensAndReusesTheTransfersWindow() throws {
        let app = AppModel(hosts: HostLibraryModel())
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            app.mainWindows.saveSizeForTermination()
            app.shutdownForTermination()
        }
        app.mainWindows.showTransfers()
        let window = try #require(NSApp.windows.first { !originalWindows.contains(ObjectIdentifier($0)) })
        #expect(window.title == String(localized: AppStrings.SFTP.transfers))
        #expect(window.isVisible)
        #expect(window.contentViewController != nil)
        app.mainWindows.showTransfers()
        #expect(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.count == 1)
        window.miniaturize(nil)
        app.mainWindows.showTransfers()
        #expect(!window.isMiniaturized)
        window.close()
        #expect(!window.isVisible)
        app.mainWindows.showTransfers()
        #expect(window.isVisible)
        #expect(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.count == 1)
    }
}
