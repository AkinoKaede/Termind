import AppKit
import UniformTypeIdentifiers

struct SFTPFileApplication: Identifiable {
    let url: URL
    let name: String
    let icon: NSImage?
    let isDefault: Bool

    var id: URL { url }
}

@MainActor
enum SFTPApplicationOpener {
    static func applications(for filename: String) -> [SFTPFileApplication] {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return [] }
        let workspace = NSWorkspace.shared
        return applications(
            urls: workspace.urlsForApplications(toOpen: type),
            defaultURL: workspace.urlForApplication(toOpen: type),
            name: {
                let name = FileManager.default.displayName(atPath: $0.path)
                return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            },
            icon: { workspace.icon(forFile: $0.path) }
        )
    }

    static func applications(
        urls: [URL], defaultURL: URL?, name: (URL) -> String, icon: (URL) -> NSImage?
    ) -> [SFTPFileApplication] {
        let preferred = defaultURL?.standardizedFileURL
        var seen: Set<URL> = []
        return (urls + (defaultURL.map { [$0] } ?? [])).compactMap { url in
            let url = url.standardizedFileURL
            guard seen.insert(url).inserted else { return nil }
            return SFTPFileApplication(url: url, name: name(url), icon: icon(url), isDefault: url == preferred)
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
        }
    }

    static func chooseApplication() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open With")
        panel.prompt = String(localized: "Open")
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return await panel.begin() == .OK ? panel.url : nil
    }

    static func open(_ url: URL, with application: URL) async throws {
        _ = try await NSWorkspace.shared.open(
            [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}
