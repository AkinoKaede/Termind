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
    func encodingRemainsStrictWhileUTF8DecodingBypassesInvalidBytes() throws {
        #expect(throws: RemoteCharsetConversionError.self) {
            _ = try RemoteCharsetStreamConverter.encode("🙂", charset: .isoLatin1)
        }

        let decoder = try RemoteCharsetStreamConverter(charset: .utf8, direction: .decoding)
        let first = try decoder.convert(Data([0x41, 0xE4]))
        let second = try decoder.convert(Data([0xB8, 0xFF, 0x42]))
        #expect(first.data + second.data == Data([0x41, 0xE4, 0xB8, 0xFF, 0x42]))
        #expect(!first.rejectedInput)
        #expect(!second.rejectedInput)
        #expect(try decoder.finish().data.isEmpty)
        #expect(try RemoteCharsetStreamConverter.decode(Data([0x41, 0xFF, 0x42]), charset: .utf8) == "A�B")
    }

    @Test
    func legacyDecoderBypassesInvalidAndIncompleteBytesInPlace() throws {
        let prefix = try RemoteCharsetStreamConverter.encode("服", charset: .gb18030)
        let suffix = try RemoteCharsetStreamConverter.encode("务", charset: .gb18030)
        let decoder = try RemoteCharsetStreamConverter(charset: .gb18030, direction: .decoding)
        let output = try decoder.convert(prefix + Data([0xFF]) + suffix)
        #expect(output.data == Data("服".utf8) + Data([0xFF]) + Data("务".utf8))
        #expect(!output.rejectedInput)

        let incomplete = try RemoteCharsetStreamConverter(charset: .gb18030, direction: .decoding)
        #expect(try incomplete.convert(Data(prefix.dropLast())).data.isEmpty)
        #expect(try incomplete.finish().data == Data(prefix.dropLast()))
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
    }

    @Test
    func shellIntegrationUsesLossyStringsForBypassedBytes() throws {
        let token = "test-token"
        var filter = RemoteCommandEventFilter(token: token, charset: .utf8)
        let update = filter.receive(Data("\u{1B}]777;TermindCommand=\(token);%FF\u{7}".utf8))
        #expect(update.events == [.commandStarted("�")])
    }

    @Test
    func workingDirectoryFrameIsRewrittenToPercentEncodedUTF8() throws {
        let path = "/服务器"
        let encoded = try RemoteCharsetStreamConverter.encode(path, charset: .gb18030)
        let escaped = encoded.map { String(format: "%%%02X", $0) }.joined()
        var filter = RemoteOSC7CharsetFilter(charset: .gb18030)
        let output = filter.receive(Data("\u{1B}]7;file://localhost\(escaped)\u{7}".utf8))
        let expected = "\u{1B}]7;file://localhost/%E6%9C%8D%E5%8A%A1%E5%99%A8\u{7}"
        #expect(String(decoding: output.data, as: UTF8.self) == expected)
    }

    @Test
    func workingDirectoryFrameRewritesBypassedBytesLossily() {
        var filter = RemoteOSC7CharsetFilter(charset: .utf8)
        let output = filter.receive(Data("\u{1B}]7;file://localhost/%FF\u{7}".utf8))
        let expected = "\u{1B}]7;file://localhost/%EF%BF%BD\u{7}"
        #expect(String(decoding: output.data, as: UTF8.self) == expected)
    }
}
