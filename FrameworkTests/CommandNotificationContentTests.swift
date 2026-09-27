import Foundation
import TermindApplication
import TermindPresentation
import Testing

@Suite
struct CommandNotificationContentTests {
    @Test(arguments: [0, 1, nil] as [Int?], ["npm\nrun\tbuild", nil, " \n\t"] as [String?])
    func completionIsOneSentenceWithTheActualResult(exitCode: Int?, command: String?) {
        let completion = TerminalCommandCompletion(command: command, exitCode: exitCode, duration: 12)
        let duration = Duration.seconds(12).formatted(.units(allowed: [.hours, .minutes, .seconds]))
        let expected: String
        if command == "npm\nrun\tbuild" {
            let preview = "npm run build"
            switch exitCode {
            case 0: expected = String(localized: "“\(preview)” completed successfully in \(duration).")
            case .some:
                expected = String(localized: "“\(preview)” failed with exit code \(1) after \(duration).")
            case nil: expected = String(localized: "“\(preview)” finished after \(duration).")
            }
        } else {
            switch exitCode {
            case 0: expected = String(localized: "Command completed successfully in \(duration).")
            case .some: expected = String(localized: "Command failed with exit code \(1) after \(duration).")
            case nil: expected = String(localized: "Command finished after \(duration).")
            }
        }
        let body = CommandNotificationContent.body(completion)
        #expect(body == expected)
        #expect(!body.contains("\n"))
    }

    @Test func longCommandKeepsTheFailureCodeAndDurationAfterTheEllipsis() {
        let completion = TerminalCommandCompletion(
            command: String(repeating: "字", count: 170), exitCode: 127, duration: 12)
        let preview = String(repeating: "字", count: 159) + "…"
        let duration = Duration.seconds(12).formatted(.units(allowed: [.hours, .minutes, .seconds]))
        #expect(
            CommandNotificationContent.body(completion)
                == String(localized: "“\(preview)” failed with exit code \(127) after \(duration)."))
    }
}
