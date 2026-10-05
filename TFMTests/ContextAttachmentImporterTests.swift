import AgentKit
import AppKit
import Foundation
import PDFKit
import TermindApplication
import TermindInfrastructure
import Testing
import ZIPFoundation

@testable import Termind

@Suite
struct ContextAttachmentImporterTests {
    @Test
    func importsUTF16Text() async throws {
        let url = temporaryFile(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "hello 世界".data(using: .utf16)?.write(to: url)

        let chip = try await ContextAttachmentImporter.importFile(at: url)

        #expect(chip.kind == .file)
        #expect(chip.content == "hello 世界")
        #expect(chip.sourceAttachment?.data == "hello 世界".data(using: .utf16))
        #expect(chip.sourceAttachment?.suggestedFilename == url.lastPathComponent)
    }

    @Test @MainActor
    func pdfKeepsOriginalBytesAlongsideExtractedText() async throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        view.string = "Hello retained PDF"
        let data = view.dataWithPDF(inside: view.bounds)
        let url = temporaryFile(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let chip = try await ContextAttachmentImporter.importFile(at: url)

        #expect(chip.content.contains("Hello retained PDF"))
        #expect(chip.sourceAttachment?.data == data)
        #expect(chip.sourceAttachment?.contentTypeIdentifier == "com.adobe.pdf")
    }

    @Test
    func extractsModernOfficePackages() async throws {
        let docx = try officePackage(
            extension: "docx",
            entries: [
                "word/document.xml": """
                <w:document xmlns:w="word"><w:body><w:p><w:r><w:t>Hello Word</w:t></w:r></w:p></w:body></w:document>
                """
            ])
        let pptx = try officePackage(
            extension: "pptx",
            entries: [
                "ppt/slides/slide1.xml": """
                <p:sld xmlns:p="presentation" xmlns:a="drawing"><a:p><a:r><a:t>Hello Slide</a:t></a:r></a:p></p:sld>
                """
            ])
        let xlsx = try officePackage(
            extension: "xlsx",
            entries: [
                "xl/sharedStrings.xml": """
                <sst><si><t>Name</t></si><si><t>Kaede</t></si></sst>
                """,
                "xl/worksheets/sheet1.xml": """
                <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row></sheetData></worksheet>
                """,
            ])
        defer {
            for url in [docx, pptx, xlsx] { try? FileManager.default.removeItem(at: url) }
        }

        #expect(try await ContextAttachmentImporter.importFile(at: docx).content.contains("Hello Word"))
        #expect(try await ContextAttachmentImporter.importFile(at: pptx).content.contains("Hello Slide"))
        #expect(try await ContextAttachmentImporter.importFile(at: xlsx).content.contains("Name\tKaede"))
    }

    @Test
    func rejectsLegacyOfficeFormat() async throws {
        let url = temporaryFile(extension: "doc")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("legacy".utf8).write(to: url)

        await #expect(throws: ContextAttachmentImporter.ImportError.self) {
            try await ContextAttachmentImporter.importFile(at: url)
        }
    }

    @Test
    func materializedAttachmentCannotEscapeItsPrivateDirectory() throws {
        let attachment = AgentContextAttachment(
            kind: .file, label: "unsafe", contentTypeIdentifier: "public.plain-text",
            suggestedFilename: "../../secret.txt", data: Data("safe".utf8)
        )
        let url = try ContextAttachmentOpener.materialize(attachment)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(url.lastPathComponent == "secret.txt")
        #expect(url.deletingLastPathComponent().lastPathComponent == attachment.id.uuidString)
        #expect(try Data(contentsOf: url) == attachment.data)
    }

    @Test @MainActor
    func rejectsImageOnlyPDFWithoutRunningOCR() async throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        let image = NSImage(size: NSSize(width: 16, height: 16))
        if let bitmap { image.addRepresentation(bitmap) }
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        let url = temporaryFile(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(document.dataRepresentation()).write(to: url)

        await #expect(throws: ContextAttachmentImporter.ImportError.self) {
            try await ContextAttachmentImporter.importFile(at: url)
        }
    }

    private func temporaryFile(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    private func officePackage(extension ext: String, entries: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, value) in entries {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: url)
        }
        let output = temporaryFile(extension: ext)
        try FileManager.default.zipItem(at: root, to: output, shouldKeepParent: false)
        return output
    }
}
