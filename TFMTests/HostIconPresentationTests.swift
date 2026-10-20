// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct HostIconPresentationTests {
    @Test(arguments: HostGeneralIcon.allCases)
    func generalArtworkIsAvailableOnMac(icon: HostGeneralIcon) {
        #expect(NSImage(systemSymbolName: icon.systemImageName, accessibilityDescription: nil) != nil)
    }

    @Test(arguments: [
        ("artix", "Artix Linux"), ("asahi", "Asahi Linux"), ("cachyos", "CachyOS"),
        ("devuan", "Devuan"), ("garuda", "Garuda Linux"), ("mx", "MX Linux"),
        ("nobara", "Nobara Linux"), ("openwrt", "OpenWrt"), ("parrot", "Parrot Security"),
        ("qubes", "Qubes OS"), ("slackware", "Slackware"), ("zorin", "Zorin"),
        ("freebsd", "FreeBSD"), ("openbsd", "OpenBSD"), ("netbsd", "NetBSD"), ("dragonfly", "BSD"),
        ("linux", "Linux"), ("unlisted-linux", "Linux"),
    ])
    func expandedCatalogMatchesSystemIdentifiers(id: String, title: String) throws {
        let distribution = try #require(DetectedDistribution(id: id))
        #expect(HostIconCatalog.entry(for: distribution)?.title == title)
    }

    @Test func bundledArtworkCanBeLoadedAndManualSelectionWins() throws {
        let catalog = HostIconCatalog.bundled
        #expect(catalog.selectableEntries.first?.title == "AlmaLinux")
        #expect(catalog.selectableEntries.last?.title == "Zorin")
        for entry in catalog.entries {
            #expect(NSImage(named: entry.asset) != nil, Comment(rawValue: entry.asset))
        }
        var host = TermindDomain.Host(
            name: "Mac", host: "example.invalid", detectedDistribution: DetectedDistribution(id: "macos"))
        #expect(HostIconCatalog.resolvedEntry(for: host)?.asset == "HostOS-macos")
        host.iconOverrideID = "windows"
        #expect(HostIconCatalog.resolvedEntry(for: host)?.asset == "HostOS-windows")
        host.iconOverrideID = "server"
        #expect(HostIconCatalog.resolvedEntry(for: host) == nil)
    }

    @Test func bundledMacOSArtworkUsesThePlatformLogoSource() throws {
        let url = try #require(Bundle.main.url(forResource: "HostIcons", withExtension: "json"))
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        let macOS = try #require(entries.first { $0["id"] as? String == "macos" })
        #expect(macOS["package"] as? String == "simple-icons")
        #expect(macOS["slug"] as? String == "macos")
    }

}

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct HostIconRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [String?.none, "cloud", "windows", "future-icon"])
    func rendersOrganizationFormInBothAppearances(language: String, selection: String?) async throws {
        let host = TermindDomain.Host(
            name: "Mac", host: "example.invalid", detectedDistribution: DetectedDistribution(id: "macos"),
            iconOverrideID: selection)
        let controller = NSHostingController(
            rootView: Form {
                HostOrganizationSection(host: .constant(host), detectedDistribution: host.detectedDistribution) {
                    LabeledContent(AppStrings.Vault.group.swiftUIKey) { Text(verbatim: "Production") }
                } tagsField: {
                    Text(AppStrings.Vault.tags)
                }
            }
            .formStyle(.grouped)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: 400, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutSubtreeIfNeeded()
            let picker = try #require(
                descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
            if selection == nil || selection == "windows" {
                #expect(picker.image?.size == NSSize(width: 16, height: 16))
            }
            if language == "en", selection == nil, appearance == .aqua {
                let capture = HostIconMenuCapture()
                NotificationCenter.default.addObserver(
                    capture, selector: #selector(HostIconMenuCapture.menuDidBeginTracking(_:)),
                    name: NSMenu.didBeginTrackingNotification, object: nil)
                picker.performClick(nil)
                NotificationCenter.default.removeObserver(capture)
                let menu = try #require(capture.menu)
                let groups = menu.items.split(whereSeparator: \.isSeparatorItem)
                #expect(
                    groups.map { $0.map(\.title) } == [
                        ["Automatic"],
                        HostGeneralIcon.allCases.map {
                            AppLocalization.string(
                                String.LocalizationValue($0.title.key), locale: Locale(identifier: "en"))
                        },
                        HostIconCatalog.bundled.selectableEntries.map(\.title),
                    ])
                let automatic = try #require(groups.first?.first)
                #expect(automatic.state == .on)
                #expect(automatic.image?.size == NSSize(width: 16, height: 16))
                let systemItems = try #require(groups.last)
                #expect(systemItems.allSatisfy { $0.image?.size == NSSize(width: 16, height: 16) })
            }
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = "host-icons-desktop-\(language)-\(selection ?? "automatic")-\(appearance.rawValue).png"
            Attachment.record(data, named: name)
            try data.write(to: FileManager.default.temporaryDirectory.appending(path: name))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class HostIconMenuCapture: NSObject {
    var menu: NSMenu?

    @objc func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        self.menu = menu
        let timer = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
            MainActor.assumeIsolated { self.menu?.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
