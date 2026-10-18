import Foundation

extension AppStrings {
    public nonisolated enum SSHExec {
        public static var handle: LocalizedStringResource { "Handle" }
        public static var command: LocalizedStringResource { "Command" }
        public static var commandOutput: LocalizedStringResource { "the command output" }
        public static var output: LocalizedStringResource { "Output" }
        public static var stdout: LocalizedStringResource { "Standard output" }
        public static var stderr: LocalizedStringResource { "Standard error" }
        public static var exitCode: LocalizedStringResource { "Exit code" }
        public static var signal: LocalizedStringResource { "Signal" }
        public static var input: LocalizedStringResource { "Input" }
        public static var stdinOpen: LocalizedStringResource { "Input open" }
        public static var stdinClosed: LocalizedStringResource { "Input closed" }
        public static var text: LocalizedStringResource { "Text" }
        public static var secret: LocalizedStringResource { "Secret" }
        public static var eof: LocalizedStringResource { "End of input" }
        public static var written: LocalizedStringResource { "Written" }
        public static var released: LocalizedStringResource { "Result released" }
        public static var foreground: LocalizedStringResource { "Foreground" }
        public static var background: LocalizedStringResource { "Background" }
        public static var noOutput: LocalizedStringResource { "No output" }
        public static var noCommands: LocalizedStringResource { "No commands in this session" }
        public static var pending: LocalizedStringResource { "Output will appear here" }
        public static var cancellationNotice: LocalizedStringResource {
            "Local tracking ended. The remote process may still be running."
        }
    }
}
