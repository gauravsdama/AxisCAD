# Security

Axis CAD is a local macOS application. Project documents and imported STEP files
remain on the machine unless the user moves or shares them. The application does
not provide accounts, telemetry, cloud storage, or a network service.

The bundled geometry kernel runs in a separate process with a bounded timeout.
Kernel requests use structured data, and failed operations leave the last valid
document in place. MCP mutations require the caller's expected document revision.

The in-app terminal executes commands with the current macOS user's permissions.
Its Codex shortcut starts a read-only sandbox, but commands typed directly by the
user are not sandboxed by Axis CAD.

Do not commit project documents, imported models, exports, screenshots, logs,
credentials, or local environment files. Report a suspected vulnerability through
GitHub's private vulnerability reporting for this repository. Include the affected
version, reproduction steps, and impact; do not include private CAD documents.
