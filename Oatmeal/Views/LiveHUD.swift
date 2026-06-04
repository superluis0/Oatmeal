import SwiftUI
import AppKit
import SwiftData

/// Owns the always-on-top floating "HUD" panel shown during a recording, so you
/// can jot notes, catch a Live Assist suggestion, and mark moments without
/// leaving your video call. A non-activating panel that floats over other apps —
/// even their full-screen spaces.
@MainActor
final class LiveHUDController {
    static let shared = LiveHUDController()
    private var panel: NSPanel?
    private(set) var isVisible = false

    func toggle(coordinator: RecordingCoordinator, context: ModelContext) {
        isVisible ? hide() : show(coordinator: coordinator, context: context)
    }

    func show(coordinator: RecordingCoordinator, context: ModelContext) {
        let content = LiveHUDView(coordinator: coordinator, context: context) { [weak self] in
            self?.hide()
        }
        if let hosting = panel?.contentView as? NSHostingView<LiveHUDView> {
            // Re-point at the current coordinator/context on every show.
            hosting.rootView = content
        }
        if panel == nil {
            let hosting = NSHostingView(rootView: content)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            // Status-bar level keeps it above video-call overlays in full-screen Spaces.
            panel.level = .statusBar
            // Show over other apps, including their full-screen Spaces (where Zoom/Teams live).
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true   // only steals key focus when you click into a field
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = hosting
            positionTopRight(panel)
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 24, y: v.maxY - size.height - 24))
    }
}

/// The floating panel's contents: status, live notes, newest suggestion, controls.
struct LiveHUDView: View {
    let coordinator: RecordingCoordinator
    let context: ModelContext
    var onClose: () -> Void

    private var notes: Binding<String> {
        Binding(
            get: { coordinator.activeMeeting?.notes ?? "" },
            set: { coordinator.activeMeeting?.notes = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Theme.hairline)

            if let suggestion = coordinator.liveSuggestions.first {
                LiveSuggestionCard(suggestion: suggestion, isLatest: true, tick: Int(coordinator.elapsed))
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Notes")
                TextEditor(text: notes)
                    .font(.system(size: 13 * Appearance.shared.fontScale))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 90)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }

            controls
        }
        .padding(14)
        .frame(minWidth: 380, minHeight: 380)
        .background(Theme.bg)
        .fontDesign(Appearance.shared.fontDesign)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text(timeString(coordinator.elapsed))
                .font(.system(.headline).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(coordinator.activeMeeting?.title ?? "Recording")
                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .help("Bring Oatmeal's main window forward")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide the floating panel")
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.markHighlight(context: context)
            } label: {
                Label("Mark", systemImage: "bookmark.fill").lineLimit(1).frame(maxWidth: .infinity)
            }
            .buttonStyle(OatGhostButton())

            Button {
                Task { await coordinator.requestSuggestion() }
            } label: {
                if coordinator.isSuggesting {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Label("Suggest", systemImage: "lightbulb.fill").lineLimit(1).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(OatSecondaryButton())
            .disabled(coordinator.isSuggesting)

            Button {
                Task { await coordinator.stop(context: context) }
            } label: {
                Label("Stop", systemImage: "stop.fill").lineLimit(1).frame(maxWidth: .infinity)
            }
            .buttonStyle(OatPrimaryButton(destructive: true))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
