// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AuthenticationServices
import Foundation
import Testing

@testable import TermindIOS

@Suite(.timeLimit(.minutes(1))) @MainActor
struct MCPWebAuthenticationPresenterTests {
    @Test func backgroundSuccessReturnsToTheMainActor() async throws {
        let url = URL(string: "https://callback.example/oauth/callback/")!
        let result = await deliver(callback: url)
        #expect(try result.get() == url)
    }

    @Test func backgroundCancellationReturnsCancellationError() async {
        let error = NSError(
            domain: ASWebAuthenticationSessionErrorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
        let result = await deliver(error: error)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func systemSetupFailureIsNotReportedAsUserCancellation() async {
        let error = NSError(
            domain: ASWebAuthenticationSessionErrorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue,
            userInfo: [NSLocalizedFailureReasonErrorKey: "Fixture: callback domain is not associated"])
        let result = await deliver(error: error)
        #expect(throws: MCPWebAuthenticationError.sessionUnavailable) { try result.get() }
    }

    @Test func backgroundFailureDoesNotExposeSystemErrorDetails() async {
        let result = await deliver(error: NSError(domain: "OAuth fixture", code: 99))
        #expect(throws: MCPWebAuthenticationError.sessionUnavailable) { try result.get() }
    }

    @Test func missingCallbackReturnsSessionUnavailable() async {
        let result = await deliver()
        #expect(throws: MCPWebAuthenticationError.sessionUnavailable) { try result.get() }
    }

    private func deliver(callback: URL? = nil, error: (any Error)? = nil) async -> Result<URL, any Error> {
        await withCheckedContinuation { continuation in
            let completion = MCPWebAuthenticationPresenter.completionHandler { result in
                MainActor.preconditionIsolated()
                #expect(Thread.isMainThread)
                continuation.resume(returning: result)
            }
            DispatchQueue(label: "MCPWebAuthenticationPresenterTests.callback").async {
                #expect(!Thread.isMainThread)
                completion(callback, error)
            }
        }
    }
}
