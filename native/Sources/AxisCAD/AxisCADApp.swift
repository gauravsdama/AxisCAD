import SwiftUI

@main
struct AxisCADApp: App {
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(store)
                .background(WindowVisibilityGuard())
        }
        // Keep the native title bar.  The hidden-title-bar style allows a
        // restored window to overlap the workspace's own toolbar, which made
        // the primary commands appear to vanish off the top edge.
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
        }
    }
}
