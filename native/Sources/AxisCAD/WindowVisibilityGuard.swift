import AppKit
import SwiftUI

/// Keeps Axis's borderless workspace window inside the usable screen area.
/// macOS restores a window's last frame before SwiftUI lays out its content;
/// a stale frame can otherwise put the top workspace toolbar under the menu
/// bar, leaving only the lower panes usable.
struct WindowVisibilityGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { confine(window: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { confine(window: nsView.window) }
    }

    private func confine(window: NSWindow?) {
        guard let window, let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        window.minSize = NSSize(width: 1050, height: 680)

        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: false)
    }
}
