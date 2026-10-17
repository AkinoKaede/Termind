import Darwin
import Foundation
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SFTPSocketRelayTests {
    @Test
    func successfulSourceCompletionMarksEOFAfterBytes() throws {
        let relay = try SFTPSocketRelay()
        defer { relay.close() }
        var sent: UInt8 = 255
        #expect(Darwin.send(relay.writer, &sent, 1, 0) == 1)
        #expect(!relay.sourceSucceeded)
        relay.finishWriting()
        var received: UInt8 = 0
        #expect(Darwin.recv(relay.reader, &received, 1, 0) == 1)
        #expect(received == sent)
        #expect(Darwin.recv(relay.reader, &received, 1, 0) == 0)
        #expect(relay.sourceSucceeded)
    }

    /// A token that was already cancelled stops the relay as soon as the
    /// observer is installed, and that EOF never authorizes a commit.
    @Test
    func alreadyCancelledTokensImmediatelyStopNewRelays() throws {
        let cancellation = TransferCancellationToken()
        cancellation.cancel()
        let relay = try SFTPSocketRelay()
        defer { relay.close() }
        let observer = cancellation.observeCancellation { relay.stop() }
        defer { cancellation.removeObserver(observer) }
        var byte: UInt8 = 0
        #expect(Darwin.recv(relay.reader, &byte, 1, 0) == 0)
        #expect(!relay.sourceSucceeded)
    }

    @Test
    func cancellationAfterBytesStillDoesNotMarkSuccessfulSourceEOF() throws {
        let relay = try SFTPSocketRelay()
        defer { relay.close() }
        var byte: UInt8 = 1
        #expect(Darwin.send(relay.writer, &byte, 1, 0) == 1)
        #expect(Darwin.recv(relay.reader, &byte, 1, 0) == 1)
        relay.stop()
        #expect(!relay.sourceSucceeded)
        #expect(Darwin.recv(relay.reader, &byte, 1, 0) == 0)
    }
}
