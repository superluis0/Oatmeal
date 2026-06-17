import AppKit
import ApplicationServices

/// Drops the latest meeting's recap into whatever app you're in — copies it to the
/// clipboard and, when Accessibility is granted, pastes it at the cursor (CGEvent
/// \u{2318}V). Triggered by a global hotkey. On-device; nothing leaves the Mac.
enum RecapPaste {
    @MainActor
    static func pasteLatestRecap() {
        guard let ctx = AppLifecycle.shared.context else {
            HUDToast.show("Open Oatmeal first.")
            return
        }
        let recap = (try? MeetingQueryService(context: ctx).latestMeetingSummary()) ?? ""
        guard !recap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            HUDToast.show("No meeting to recap yet.")
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(recap, forType: .string)

        if AXIsProcessTrusted() {
            // Synthesize ⌘V into the frontmost app.
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)  // 'v'
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            HUDToast.show("Recap pasted \u{2713}")
        } else {
            HUDToast.show("Recap copied \u{2014} press \u{2318}V to paste. (Grant Accessibility to auto-paste.)")
        }
    }
}

/// A tiny, auto-dismissing floating toast for global-hotkey feedback (the regular
/// in-app toasts are view-scoped; this works even when Oatmeal isn't focused).
@MainActor
enum HUDToast {
    private static var panel: NSPanel?

    static func show(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let pad: CGFloat = 16
        let size = NSSize(width: min(520, label.frame.width + pad * 2), height: label.frame.height + pad)
        label.frame = NSRect(x: pad, y: pad / 2, width: size.width - pad * 2, height: label.frame.height)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 12
        container.addSubview(label)

        panel?.orderOut(nil)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.contentView = container
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 90))
        }
        p.orderFrontRegardless()
        panel = p

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak p] in
            guard p === panel else { return }   // a newer toast replaced it
            p?.orderOut(nil)
        }
    }
}
