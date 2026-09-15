import Foundation
import Combine

/// A user-operated shell session for the Terminal window. This is deliberately
/// separate from `CodexService`: the assistant uses typed MCP operations and a
/// read-only Codex sandbox, whereas this session runs only commands explicitly
/// entered by the person using Axis CAD.
@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false
    @Published var launchError: String?

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private let maxTranscriptCharacters = 180_000

    deinit {
        outputHandle?.readabilityHandler = nil
        process?.terminate()
    }

    func start(in workingDirectory: URL) {
        guard !isRunning else { return }
        transcript = "Axis CAD terminal\r\nUser-entered commands run in: \(workingDirectory.path)\r\nType `codex --sandbox read-only` to start Codex manually.\r\n\r\n"
        launchError = nil

        let input = Pipe()
        let output = Pipe()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // `script` allocates a pseudo-terminal, which lets interactive tools such
        // as Codex receive a TTY instead of plain stdin/stdout pipes.
        shell.arguments = [
            "-q", "/dev/null", "/usr/bin/env",
            "TERM=xterm-256color", "COLORTERM=truecolor",
            "/bin/zsh", "-il"
        ]
        shell.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        // Desktop apps frequently inherit TERM=dumb. Interactive Codex checks
        // this before starting its TUI, so advertise the terminal capability
        // supplied by the pseudo-terminal session.
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        shell.environment = environment
        shell.standardInput = input
        shell.standardOutput = output
        shell.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.append(text) }
        }
        shell.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.append("\r\n[terminal exited with status \(process.terminationStatus)]\r\n")
                self?.outputHandle?.readabilityHandler = nil
                self?.inputHandle = nil
                self?.outputHandle = nil
                self?.process = nil
                self?.isRunning = false
            }
        }

        do {
            try shell.run()
            process = shell
            inputHandle = input.fileHandleForWriting
            outputHandle = output.fileHandleForReading
            isRunning = true
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            launchError = "Could not start the local terminal: \(error.localizedDescription)"
            append("[terminal launch failed: \(error.localizedDescription)]\r\n")
        }
    }

    func send(_ command: String) {
        guard isRunning else { return }
        let line = command.hasSuffix("\n") || command.hasSuffix("\r") ? command : command + "\n"
        write(line)
    }

    func sendInput(_ input: String) {
        guard isRunning else { return }
        write(input)
    }

    private func write(_ input: String) {
        guard let data = input.data(using: .utf8) else { return }
        do { try inputHandle?.write(contentsOf: data) }
        catch { append("[unable to write to terminal: \(error.localizedDescription)]\r\n") }
    }

    func stop() {
        outputHandle?.readabilityHandler = nil
        process?.terminate()
        inputHandle = nil
        outputHandle = nil
        process = nil
        isRunning = false
    }

    func clear() { transcript = "" }

    private func append(_ text: String) {
        transcript += text
        if transcript.count > maxTranscriptCharacters {
            transcript = "[older terminal output cleared]\r\n" + String(transcript.suffix(maxTranscriptCharacters))
        }
    }
}
