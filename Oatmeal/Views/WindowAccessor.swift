import SwiftUI
import AppKit

/// Reaches the hosting NSWindow (and its NavigationSplitView's underlying
/// NSSplitView) to enforce a usable window minimum size AND a sidebar width that
/// isn't undercut by a tiny restored frame/divider position from a prior launch.
struct WindowConfigurator: NSViewRepresentable {
    var minSize = NSSize(width: 960, height: 640)
    var preferred = NSSize(width: 1200, height: 800)
    var sidebarWidth: CGFloat = 264

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.start(view: view, minSize: minSize, preferred: preferred, sidebarWidth: sidebarWidth)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var windowTries = 0
        private var sidebarTries = 0
        private var didSizeWindow = false

        func start(view: NSView, minSize: NSSize, preferred: NSSize, sidebarWidth: CGFloat) {
            configureWindow(view: view, minSize: minSize, preferred: preferred)
            fixSidebar(view: view, width: sidebarWidth)
        }

        private func configureWindow(view: NSView, minSize: NSSize, preferred: NSSize) {
            guard windowTries < 80 else { return }
            windowTries += 1
            guard let window = view.window else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                    if let view { self.configureWindow(view: view, minSize: minSize, preferred: preferred) }
                }
                return
            }
            window.minSize = minSize
            if !didSizeWindow {
                didSizeWindow = true
                if window.frame.width < minSize.width || window.frame.height < minSize.height {
                    window.setContentSize(preferred)
                    window.center()
                }
            }
        }

        /// Force the sidebar column to a sensible width if a narrow position was restored.
        private func fixSidebar(view: NSView, width: CGFloat) {
            guard sidebarTries < 80 else { return }
            sidebarTries += 1
            if let window = view.window,
               let split = Self.findSplitView(in: window.contentView),
               split.arrangedSubviews.count >= 2 {
                let current = split.arrangedSubviews[0].frame.width
                if abs(current - width) > 1 {
                    split.setPosition(width, ofDividerAt: 0)
                }
                // Re-assert a couple of times to win against late restoration/layout.
                if sidebarTries < 6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in
                        if let view { self.fixSidebar(view: view, width: width) }
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                    if let view { self.fixSidebar(view: view, width: width) }
                }
            }
        }

        private static func findSplitView(in view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews {
                if let found = findSplitView(in: sub) { return found }
            }
            return nil
        }
    }
}
