import SwiftUI
import WebKit

struct TerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: TerminalSession
    let workingDirectory: URL
    @State private var command = ""
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Axis CAD terminal").font(.headline)
                    Text("Manual commands only · the in-app assistant continues to use revision-safe MCP tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.isRunning ? "RUNNING" : "STOPPED")
                    .font(.caption.monospaced()).foregroundStyle(session.isRunning ? .green : .secondary)
                Button("Clear") { session.clear() }
                Button("Interrupt") { session.sendInput("\u{03}") }.disabled(!session.isRunning)
                Button(session.isRunning ? "Stop" : "Start") {
                    if session.isRunning { session.stop() }
                    else { session.start(in: workingDirectory); started = true }
                }
                .buttonStyle(.borderedProminent)
                Button("Close") { session.stop(); dismiss() }
            }
            .padding(16)

            HStack(spacing: 8) {
                Button("Launch Codex") { session.send("codex --sandbox read-only") }.disabled(!session.isRunning)
                Button("Axis MCP status") { session.send("codex mcp list") }.disabled(!session.isRunning)
                Button("Show document folder") { session.send("pwd && ls -la") }.disabled(!session.isRunning)
                Spacer()
                Text(workingDirectory.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.bottom, 10)

            TerminalEmulator(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.88))

            HStack(spacing: 10) {
                Text(">").font(.body.monospaced()).foregroundStyle(.green)
                TextField("Enter a local command…", text: $command)
                    .textFieldStyle(.plain).font(.body.monospaced()).onSubmit(sendCommand).disabled(!session.isRunning)
                Button("Run", action: sendCommand).disabled(!session.isRunning || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14).background(.bar)
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            guard !started, !session.isRunning else { return }
            session.start(in: workingDirectory)
            started = true
        }
        .onDisappear { session.stop() }
        .alert("Terminal", isPresented: Binding(get: { session.launchError != nil }, set: { if !$0 { session.launchError = nil } })) {
            Button("OK", role: .cancel) { session.launchError = nil }
        } message: { Text(session.launchError ?? "") }
    }

    private func sendCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.send(trimmed)
        command = ""
    }
}

private struct TerminalEmulator: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "axisTerminalInput")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        guard let url = Bundle.module.url(forResource: "terminal", withExtension: "html") else { return view }
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let transcript = session.transcript
        if transcript.count < context.coordinator.renderedCharacters {
            context.coordinator.renderedCharacters = 0
            view.evaluateJavaScript("window.axisTerminalClear && window.axisTerminalClear();")
        }
        guard transcript.count > context.coordinator.renderedCharacters else { return }
        let suffix = String(transcript.dropFirst(context.coordinator.renderedCharacters))
        context.coordinator.renderedCharacters = transcript.count
        guard let encoded = try? JSONEncoder().encode(suffix), let literal = String(data: encoded, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.axisTerminalWrite && window.axisTerminalWrite(\(literal));")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let session: TerminalSession
        var renderedCharacters = 0

        init(session: TerminalSession) { self.session = session }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "axisTerminalInput", let data = message.body as? String else { return }
            session.sendInput(data)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            renderedCharacters = 0
            guard !session.transcript.isEmpty,
                  let encoded = try? JSONEncoder().encode(session.transcript),
                  let literal = String(data: encoded, encoding: .utf8) else { return }
            renderedCharacters = session.transcript.count
            webView.evaluateJavaScript("window.axisTerminalWrite(\(literal));")
        }
    }
}
