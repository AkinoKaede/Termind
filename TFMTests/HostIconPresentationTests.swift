import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct HostIconPresentationTests {
    @Test func bundledArtworkCanBeLoadedAndManualSelectionWins() throws {
        let catalog = HostIconCatalog.bundled
        #expect(catalog.selectableEntries.prefix(2).map(\.id) == ["macos", "windows"])
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

    @Test(arguments: ["000000", "0078D4"], [ColorScheme.light, .dark])
    func brandColorsMeetIconSurfaceContrast(hex: String, scheme: ColorScheme) throws {
        let color = try #require(HostIconBrandColor.color(hex: hex, colorScheme: scheme))
        let foreground = try #require(NSColor(color).usingColorSpace(.deviceRGB))
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        var background: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            background = NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB)
        }
        let surface = try #require(background)
        let front = [foreground.redComponent, foreground.greenComponent, foreground.blueComponent]
        let back = [surface.redComponent, surface.greenComponent, surface.blueComponent]
        let tinted = zip(front, back).map { $1 * 0.84 + $0 * 0.16 }
        func luminance(_ components: [CGFloat]) -> CGFloat {
            let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let a = luminance(front)
        let b = luminance(tinted)
        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 3)
    }
}

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct HostIconRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func rendersOrganizationFormInBothAppearances(language: String) async throws {
        let host = TermindDomain.Host(name: "Mac", host: "example.invalid", iconOverrideID: "windows")
        let controller = NSHostingController(
            rootView: Form {
                HostOrganizationSection(host: .constant(host)) {
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
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = "host-icons-desktop-\(language)-\(appearance.rawValue).png"
            Attachment.record(data, named: name)
            try data.write(to: FileManager.default.temporaryDirectory.appending(path: name))
        }
    }
}
