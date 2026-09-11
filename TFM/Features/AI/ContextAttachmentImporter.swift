import AgentKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

nonisolated enum ContextAttachmentImporter {
    static let maximumFileBytes = 25 * 1_024 * 1_024
    static let maximumImageBytes = 5 * 1_024 * 1_024
    static let maximumTextCharacters = 200_000
    static let maximumImageDimension = 2_048
    static let maximumAttachments = 20

    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [
            .text, .sourceCode, .json, .xml, .propertyList,
            .commaSeparatedText, .tabSeparatedText, .pdf, .image,
        ]
        for ext in [
            "docx", "xlsx", "pptx", "md", "yaml", "yml", "toml", "conf", "env",
            "log", "ini", "sh", "zsh", "fish",
        ] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    static func importFile(at url: URL) async throws -> ContextChip {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ImportError.notAFile }
            guard (values.fileSize ?? 0) <= maximumFileBytes else {
                throw ImportError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            try Task.checkCancellation()
            let ext = url.pathExtension.lowercased()
            let label = url.lastPathComponent

            if ["doc", "xls", "ppt"].contains(ext) { throw ImportError.legacyOffice }
            if ext == "pdf" {
                return fileChip(label: label, data: data, content: try pdfText(data), url: url)
            }
            if ext == "docx" {
                return fileChip(label: label, data: data, content: try docxText(data), url: url)
            }
            if ext == "pptx" {
                return fileChip(label: label, data: data, content: try pptxText(data), url: url)
            }
            if ext == "xlsx" {
                return fileChip(label: label, data: data, content: try xlsxText(data), url: url)
            }
            if isImage(url: url) {
                let image = try normalizedImage(data: data, label: label)
                return ContextChip(kind: .image, label: label, image: image)
            }
            guard isText(url: url) else { throw ImportError.unsupportedFormat }
            return fileChip(label: label, data: data, content: try decodedText(data), url: url)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func importImage(data: Data, label: String = "Pasted image") async throws -> ContextChip {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try normalizedImage(data: data, label: label)
            return ContextChip(kind: .image, label: label, image: image)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func pastedText(_ text: String) throws -> ContextChip {
        try validate(text)
        return ContextChip(kind: .pastedText, label: String(localized: "Pasted text"), content: text)
    }

    static func shouldAttachPastedText(_ text: String) -> Bool {
        text.count >= 2_000 || text.split(separator: "\n", omittingEmptySubsequences: false).count >= 20
    }

    private static func fileChip(
        label: String, data: Data, content: String, url: URL
    ) -> ContextChip {
        let attachment = AgentContextAttachment(
            kind: .file, label: label,
            contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier
                ?? UTType.data.identifier,
            suggestedFilename: label, data: data
        )
        return ContextChip(
            id: attachment.id, kind: .file, label: label, content: content,
            sourceAttachment: attachment
        )
    }

    private static func isImage(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func isText(url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .text) {
            return true
        }
        return [
            "md", "yaml", "yml", "toml", "conf", "env", "log", "ini", "sh", "zsh",
            "fish",
        ].contains(url.pathExtension.lowercased())
    }

    private static func decodedText(_ data: Data) throws -> String {
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        guard let text = encodings.lazy.compactMap({ String(data: data, encoding: $0) }).first else {
            throw ImportError.unsupportedFormat
        }
        try validate(text)
        return text
    }

    private static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw ImportError.unreadableDocument
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard
                let value = document.page(at: index)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { continue }
            pages.append("--- Page \(index + 1) ---\n\(value)")
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.isEmpty else { throw ImportError.scannedPDF }
        try validate(text)
        return text
    }

    private static func docxText(_ data: Data) throws -> String {
        let archive = try officeArchive(data)
        guard let xml = try archiveData(archive, path: "word/document.xml") else {
            throw ImportError.unreadableDocument
        }
        let parser = ParagraphTextParser(paragraphElements: ["p"], cellElements: ["tc"])
        let text = try parser.parse(xml)
        try validateNonempty(text)
        return text
    }

    private static func pptxText(_ data: Data) throws -> String {
        let archive = try officeArchive(data)
        let slidePaths = archive.map(\.path).filter {
            $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml")
                && !$0.contains("/_rels/")
        }.sorted(by: naturalPathOrder)
        var slides: [String] = []
        for (index, path) in slidePaths.enumerated() {
            guard let xml = try archiveData(archive, path: path) else { continue }
            let value = try ParagraphTextParser(paragraphElements: ["p"]).parse(xml)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { slides.append("--- Slide \(index + 1) ---\n\(value)") }
            try validate(slides.joined(separator: "\n\n"))
        }
        let text = slides.joined(separator: "\n\n")
        try validateNonempty(text)
        return text
    }

    private static func xlsxText(_ data: Data) throws -> String {
        let archive = try officeArchive(data)
        let shared: [String]
        if let xml = try archiveData(archive, path: "xl/sharedStrings.xml") {
            shared = try SharedStringsParser().parse(xml)
        } else {
            shared = []
        }
        let sheetPaths = archive.map(\.path).filter {
            $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml")
                && !$0.contains("/_rels/")
        }.sorted(by: naturalPathOrder)
        var sheets: [String] = []
        for (index, path) in sheetPaths.enumerated() {
            guard let xml = try archiveData(archive, path: path) else { continue }
            let value = try WorksheetTextParser(sharedStrings: shared).parse(xml)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sheets.append("--- Sheet \(index + 1) ---\n\(value)") }
            try validate(sheets.joined(separator: "\n\n"))
        }
        let text = sheets.joined(separator: "\n\n")
        try validateNonempty(text)
        return text
    }

    private static func officeArchive(_ data: Data) throws -> Archive {
        do {
            let archive = try Archive(data: data, accessMode: .read)
            let expandedBytes = archive.reduce(UInt64(0)) {
                $0 + UInt64($1.uncompressedSize)
            }
            guard expandedBytes <= UInt64(maximumFileBytes * 2) else {
                throw ImportError.fileTooLarge
            }
            return archive
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadableDocument
        }
    }

    private static func archiveData(_ archive: Archive, path: String) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        guard entry.uncompressedSize <= UInt32(maximumFileBytes) else {
            throw ImportError.fileTooLarge
        }
        var result = Data()
        _ = try archive.extract(entry) { result.append($0) }
        return result
    }

    private static func normalizedImage(data: Data, label: String) throws -> AgentImageAttachment {
        guard data.count <= maximumFileBytes,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { throw ImportError.unreadableImage }
        var dimension = maximumImageDimension
        while dimension >= 512 {
            try Task.checkCancellation()
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
            ]
            guard
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary
                )
            else { throw ImportError.unreadableImage }
            let alpha = image.alphaInfo
            let hasAlpha =
                alpha == .first || alpha == .last
                || alpha == .premultipliedFirst || alpha == .premultipliedLast
            let type = hasAlpha ? UTType.png : UTType.jpeg
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, type.identifier as CFString, 1, nil
                )
            else { throw ImportError.unreadableImage }
            let properties: [CFString: Any] =
                hasAlpha
                ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.84]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ImportError.unreadableImage
            }
            let normalized = output as Data
            if normalized.count <= maximumImageBytes {
                return AgentImageAttachment(
                    label: label, mimeType: type.preferredMIMEType ?? "image/jpeg",
                    data: normalized, pixelWidth: image.width, pixelHeight: image.height
                )
            }
            dimension /= 2
        }
        throw ImportError.imageTooLarge
    }

    private static func validateNonempty(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.noText
        }
        try validate(text)
    }

    private static func validate(_ text: String) throws {
        guard text.count <= maximumTextCharacters else { throw ImportError.textTooLarge }
    }

    private static func naturalPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    enum ImportError: LocalizedError {
        case notAFile, fileTooLarge, imageTooLarge, textTooLarge, unsupportedFormat
        case legacyOffice, unreadableDocument, unreadableImage, scannedPDF, noText

        var errorDescription: String? {
            switch self {
            case .notAFile: String(localized: "Folders cannot be attached.")
            case .fileTooLarge: String(localized: "The file is larger than 25 MB.")
            case .imageTooLarge: String(localized: "The normalized image is larger than 5 MB.")
            case .textTooLarge: String(localized: "The extracted text is longer than 200,000 characters.")
            case .unsupportedFormat: String(localized: "This file format is not supported.")
            case .legacyOffice: String(localized: "Convert legacy Office files to DOCX, XLSX, or PPTX first.")
            case .unreadableDocument: String(localized: "The document is encrypted, damaged, or unreadable.")
            case .unreadableImage: String(localized: "The image cannot be decoded.")
            case .scannedPDF: String(localized: "This PDF has no selectable text. Scanned PDFs are not supported.")
            case .noText: String(localized: "The document contains no extractable text.")
            }
        }
    }
}

nonisolated private final class ParagraphTextParser: NSObject, XMLParserDelegate {
    let paragraphElements: Set<String>
    let cellElements: Set<String>
    var output = ""
    var captured = ""
    var capturesText = false

    init(paragraphElements: Set<String>, cellElements: Set<String> = []) {
        self.paragraphElements = paragraphElements
        self.cellElements = cellElements
    }

    func parse(_ data: Data) throws -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw ContextAttachmentImporter.ImportError.unreadableDocument }
        return output.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "t" {
            capturesText = true
            captured = ""
        }
        if name == "tab" { output += "\t" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesText { captured += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "t" {
            output += captured
            capturesText = false
        }
        if cellElements.contains(name) { output += "\t" }
        if paragraphElements.contains(name) { output += "\n" }
    }
}

nonisolated private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    var value = ""
    var text = ""
    var inItem = false
    var inText = false

    func parse(_ data: Data) throws -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw ContextAttachmentImporter.ImportError.unreadableDocument }
        return strings
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "si" {
            inItem = true
            value = ""
        }
        if name == "t", inItem {
            inText = true
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "t", inText {
            value += text
            inText = false
        }
        if name == "si" {
            strings.append(value)
            inItem = false
        }
    }
}

nonisolated private final class WorksheetTextParser: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var rows: [String] = []
    var cells: [String] = []
    var cellType = ""
    var cellReference = ""
    var captured = ""
    var captureElement: String?

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    func parse(_ data: Data) throws -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw ContextAttachmentImporter.ImportError.unreadableDocument }
        return rows.joined(separator: "\n")
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "row" { cells = [] }
        if name == "c" {
            cellType = attributeDict["t"] ?? ""
            cellReference = attributeDict["r"] ?? ""
            let column = Self.columnIndex(cellReference)
            while cells.count < column { cells.append("") }
        }
        if name == "v" || name == "t" {
            captureElement = name
            captured = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureElement != nil { captured += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == captureElement {
            var value = captured
            if cellType == "s", let index = Int(captured), sharedStrings.indices.contains(index) {
                value = sharedStrings[index]
            }
            if cells.isEmpty { cells.append(value) } else { cells[cells.count - 1] = value }
            captureElement = nil
        }
        if name == "row" { rows.append(cells.joined(separator: "\t")) }
    }

    private static func columnIndex(_ reference: String) -> Int {
        var value = 0
        for scalar in reference.unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
            value = value * 26 + Int(scalar.value - 64)
        }
        return max(1, value)
    }
}
