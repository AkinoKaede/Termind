import Foundation
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct RemoteCharsetTests {
    @Test(
        arguments: [
            (RemoteCharset.utf8, "服务器🙂"),
            (.gb18030, "服务器"),
            (.big5, "伺服器"),
            (.shiftJIS, "サーバー"),
            (.eucJP, "サーバー"),
            (.eucKR, "서버"),
            (.isoLatin1, "café"),
            (.windows1252, "“café” €"),
        ]
    )
    func roundTripsEverySupportedCharset(charset: RemoteCharset, value: String) throws {
        let encoded = try RemoteCharsetStreamConverter.encode(value, charset: charset)
        #expect(try RemoteCharsetStreamConverter.decode(encoded, charset: charset) == value)
    }

    @Test
    func decoderRetainsEveryPossibleMultibyteBoundary() throws {
        let value = "服务器"
        let encoded = try RemoteCharsetStreamConverter.encode(value, charset: .gb18030)
        for split in 0...encoded.count {
            let decoder = try RemoteCharsetStreamConverter(charset: .gb18030, direction: .decoding)
            var output = try decoder.convert(Data(encoded.prefix(split))).data
            output.append(try decoder.convert(Data(encoded.dropFirst(split))).data)
            output.append(try decoder.finish().data)
            #expect(String(data: output, encoding: .utf8) == value)
        }
    }

    @Test
    func strictConversionNeverProducesReplacementText() throws {
        #expect(throws: RemoteCharsetConversionError.self) {
            _ = try RemoteCharsetStreamConverter.encode("🙂", charset: .isoLatin1)
        }
        #expect(throws: RemoteCharsetConversionError.self) {
            _ = try RemoteCharsetStreamConverter.decode(Data([0xFF]), charset: .utf8)
        }

        let decoder = try RemoteCharsetStreamConverter(charset: .utf8, direction: .decoding)
        let output = try decoder.convert(Data([0x41, 0xFF, 0x42]), recoveringInvalidInput: true)
        #expect(output.rejectedInput)
        #expect(output.data == Data("AB".utf8))
        #expect(output.data.range(of: Data("�".utf8)) == nil)
    }

    @Test
    func incompleteTrailingInputIsRejectedOnlyWhenFinished() throws {
        let decoder = try RemoteCharsetStreamConverter(charset: .utf8, direction: .decoding)
        #expect(try decoder.convert(Data([0xE4, 0xB8])).data.isEmpty)
        #expect(throws: RemoteCharsetConversionError.self) { _ = try decoder.finish() }
    }

    @Test
    func shellIntegrationPayloadUsesTheRemoteCharset() throws {
        let token = "test-token"
        let command = "查看服务器"
        let encoded = try RemoteCharsetStreamConverter.encode(command, charset: .gb18030)
        let escaped = encoded.map { String(format: "%%%02X", $0) }.joined()
        var filter = RemoteCommandEventFilter(token: token, charset: .gb18030)
        let update = filter.receive(Data("\u{1B}]777;TermindCommand=\(token);\(escaped)\u{7}".utf8))
        #expect(update.events == [.commandStarted(command)])
        #expect(!update.rejectedCharsetInput)
    }

    @Test
    func workingDirectoryFrameIsRewrittenToPercentEncodedUTF8() throws {
        let path = "/服务器"
        let encoded = try RemoteCharsetStreamConverter.encode(path, charset: .gb18030)
        let escaped = encoded.map { String(format: "%%%02X", $0) }.joined()
        var filter = RemoteOSC7CharsetFilter(charset: .gb18030)
        let output = filter.receive(Data("\u{1B}]7;file://localhost\(escaped)\u{7}".utf8))
        #expect(!output.rejectedInput)
        let expected = "\u{1B}]7;file://localhost/%E6%9C%8D%E5%8A%A1%E5%99%A8\u{7}"
        #expect(String(decoding: output.data, as: UTF8.self) == expected)
    }
}
