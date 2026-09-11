import TermindApplication

extension ContextAttachmentLoading {
    public static let live = Self(
        file: { try await ContextAttachmentImporter.importFile(at: $0) },
        image: { try await ContextAttachmentImporter.importImage(data: $0, label: $1) })
}
