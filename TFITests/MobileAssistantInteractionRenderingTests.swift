import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAssistantInteractionRenderingTests {
    @Test func approvalTextRetainsItsNaturalHeight() {
        func height(_ text: String) -> CGFloat {
            let controller = UIHostingController(
                rootView: AssistantApprovalDetails(
                    detail: AgentToolDetail(items: [.text(.init(text: text, style: .monospaced))]),
                    reasons: [], showsSafetyDetails: .constant(false)
                )
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, .large))
            return controller.sizeThatFits(in: CGSize(width: 340, height: 600)).height
        }
        let single = height("sudo systemctl restart nginx")
        let multiple = height("cd /srv/app\npwd\nsudo systemctl restart nginx")
        #expect(single >= 12)
        #expect(multiple >= single * 2.5)
    }

    @Test func keyboardAuthenticationMeasuresItsVisibleFields() {
        func height(promptCount: Int) -> CGFloat {
            let challenge = SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: UUID(), hostname: "prod.example.com", port: 22,
                username: "deploy", round: 1, name: "", instruction: "",
                prompts: (0..<promptCount).map { .init(text: "Verification code \($0)", echo: false) })
            let controller = UIHostingController(
                rootView: SSHKeyboardInteractiveForm(challenge: challenge, submit: { _ in }, cancel: {})
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.dynamicTypeSize, .large))
            return controller.sizeThatFits(in: CGSize(width: 340, height: 600)).height
        }
        let single = height(promptCount: 1)
        let multiple = height(promptCount: 3)
        #expect(single > 100)
        #expect(multiple > single + 80)
    }
}
