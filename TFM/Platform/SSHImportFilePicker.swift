import AppKit

@MainActor
enum SSHImportFilePicker {
    static func choose(folder: Bool, suggestedPath: String? = nil) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let suggestedPath {
            let url = URL(fileURLWithPath: suggestedPath)
            panel.directoryURL = folder ? url : url.deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
        }
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
}
