# Axis CAD Development Guidance

Axis CAD is a native macOS application. The production direction is SwiftUI +
Metal with a local Codex MCP bridge. The Vite prototype remains a reference and
must not become the primary runtime again.

## Architecture boundaries

- `native/` owns the macOS app, document model, Metal renderer, and export.
- `mcp/` owns Codex-facing semantic CAD operations.
- Both surfaces share `~/Library/Application Support/AxisCAD/active-document.json`.
- Never make the AI drive the macOS UI. AI geometry changes must use typed MCP
  operations with revision checks.
- Never claim BRep/topology correctness until a real CAD-kernel adapter validates it.
- Keep the packaged app small. Heavy geometry engines run out of process and are
  optional adapters, not renderer dependencies.

## Required checks

Run the complete gate after meaningful changes:

```bash
npm run check
```

For every native UI change, also verify the exact text inventory:

```bash
python3 native/scripts/inventory-swift-ui-copy.py --source native/Sources --output docs/product/UI_COPY_FULL.md --name 'Axis CAD' --check
```

`docs/product/UI_COPY.md` and `docs/product/UI_COPY_FULL.md` are human-owned copy records. Preserve their wording exactly; do not add eyebrows, repeated page titles, promotional headings, AI signposting, or unrequested helper copy. Update the Markdown first when the owner approves a wording change.

For a native UI change, also launch `native/build/AxisCAD.app` and exercise the
affected control. For an MCP change, use the SDK integration tests and verify a
live edit reloads in the running native app.

## Safety

- Preserve the last valid document on failures.
- Use atomic file replacement and `expected_revision` on mutations.
- Create checkpoints before destructive or multi-feature AI work.
- Keep Codex shell execution read-only from the in-app assistant; document
  mutation belongs to the MCP tools.
