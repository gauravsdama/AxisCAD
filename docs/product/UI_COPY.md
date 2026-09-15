# Axis CAD UI copy inventory

Human editorial source of truth for the native macOS UI. Runtime strings remain in Swift; implement approved changes there and update this table in the same change. The Vite prototype is reference-only and is not inventoried as the product UI.

| ID | Screen / state | Current text | Purpose / user intent | Proposed human rewrite | Status | Implementation location | Notes |
|---|---|---|---|---|---|---|---|
| `axis.workspace.identity` | Main workspace | Axis CAD / Model / Assembly / History | Establish product and workspace modes | Keep | inventory | `native/Sources/AxisCAD/WorkspaceView.swift` | Verify current selection is announced, not color-only. |
| `axis.workspace.empty` | Empty model tree / viewport | No features yet / Add a feature to begin | Direct first action | Start with a box, sketch, or imported STEP file. | inventory | `WorkspaceView.swift` | Needs keyboard-reachable suggested actions. |
| `axis.workspace.kernel` | Exact geometry | Exact geometry / The exact geometry engine loads only when needed. / Check Solid | Explain solid validation and STEP support without exposing an internal dependency name | Keep | approved | `WorkspaceView.swift`, `CADStore.swift` | Never imply topology correctness when the adapter is absent. |
| `axis.workspace.save` | File actions / dirty state | Save / Save As… / Unsaved changes | Preserve work | Keep | inventory | `WorkspaceView.swift`, `AxisCADApp.swift` | Confirm failure preserves the last valid document. |
| `axis.sketch.hint` | Sketch editor | Dynamic tool instructions | Explain the next drawing gesture | Review per-tool text after keyboard test | inventory | `ProfileSketchEditorView.swift` | Include cancel/finish language and constraint-error recovery. |
| `axis.drawing.export` | Drawing sheet | Return to 3D model / Vector PDF / Editable DXF | Navigate and export | Keep | inventory | `DrawingSheetView.swift` | Export completion and errors need destination-specific confirmation. |
| `axis.terminal.launch` | Terminal drawer | Terminal / Launch Codex (read-only) | Open an advanced local shell workflow | Keep, with “Commands run with your macOS permissions.” nearby | inventory | `TerminalView.swift` | Security consequence cannot live only in README. |
| `axis.assistant.error` | AI command failure | Dynamic service error | Explain why a semantic edit failed | Preserve exact failure plus a safe next step | inventory | `CodexService.swift`, `WorkspaceView.swift` | Stale-revision and validation failures need different recovery text. |
| `axis.destructive.checkpoint` | Restore / delete feature | Restore checkpoint / Delete feature | Confirm model-changing action | Restore checkpoint / Delete feature | inventory | `WorkspaceView.swift` | State affected feature count and whether undo is available. |
| `axis.a11y.drawing` | Drawing canvas accessibility | Technical drawing for {name}, revision {n} | Name a non-text canvas | Keep | inventory | `DrawingSheetView.swift` | Metal viewport needs equivalent selection and geometry summaries. |

## Copy contract

The exact source inventory in `UI_COPY_FULL.md` is part of the release gate. New
visible strings require an intentional edit here, a regenerated inventory, and a
native UI review. Do not add promotional headings, eyebrows, repeated page titles,
AI signposting, or dependency names where a user-facing capability label is clearer.
