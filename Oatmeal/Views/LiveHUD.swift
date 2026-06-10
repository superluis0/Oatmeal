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
            // Wide-and-short, like a teleprompter strip, so a single glance near the
            // top of the screen (where your webcam / the other person's face sits)
            // reads the cue without an obvious eye dart toward a corner panel.
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            // Status-bar level keeps it above video-call overlays in full-screen Spaces.
            panel.level = .statusBar
            // Show over other apps, including their full-screen Spaces (where Zoom/Teams live).
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            // Let the translucent SwiftUI material show through the window itself, so
            // it reads as a soft strip floating over the call, not an opaque app window.
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true   // only steals key focus when you click into a field
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = hosting
            positionTopCenter(panel)
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Centered horizontally, near the top of the screen — close to the eyeline of a
    /// video call so glancing at it looks like looking at the person.
    private func positionTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - 16))
    }
}

/// The floating panel's contents: status, live notes, newest suggestion, controls.
struct LiveHUDView: View {
    let coordinator: RecordingCoordinator
    let context: ModelContext
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Entrance animation state. The HUD "springs into" existence when recording
    // starts, then settles. A one-shot guard keeps it from replaying on
    // re-renders (e.g. when the coordinator/context is re-pointed on show()).
    @State private var didAppear = false

    /// Notes stay hidden by default to keep the strip glanceable; toggled from the
    /// header when you actually want to jot something.
    @State private var showNotes = false

    private var notes: Binding<String> {
        Binding(
            get: { coordinator.activeMeeting?.notes ?? "" },
            set: { coordinator.activeMeeting?.notes = $0 }
        )
    }

    var body: some View {
        content
            // Spring scale-up + fade, anchored to the top edge the panel hangs from,
            // so it reads as easing down into your eyeline. Under reduce-motion both
            // values start at their settled state and never animate (see .onAppear).
            .scaleEffect(didAppear ? 1 : 0.96, anchor: .top)
            .opacity(didAppear ? 1 : 0)
            .onAppear {
                guard !didAppear else { return }
                if reduceMotion {
                    // Appear instantly — no spring/scale/slide.
                    didAppear = true
                } else {
                    // A bouncy pop so it feels like it springs into existence,
                    // then settles. Uses the shared Motion spring token.
                    withAnimation(Motion.pop(false)) {
                        didAppear = true
                    }
                }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // The cue (and optional notes) scroll between the fixed header and
            // controls, so a long suggestion never clips the Stop button.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    cue
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25),
                                   value: coordinator.liveSuggestions.first?.id)

                    if showNotes {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(text: "Notes")
                            TextEditor(text: notes)
                                .font(.system(size: 13 * Appearance.shared.fontScale))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 80)
                                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            controls
        }
        .padding(16)
        .frame(minWidth: 560)
        // Translucent material (panel is non-opaque) so the strip floats softly over
        // the call instead of reading as a solid app window.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fontDesign(Appearance.shared.fontDesign)
    }

    /// The glanceable cue: the latest suggestion in teleprompter style, or a quiet
    /// resting line when there's nothing to say yet.
    @ViewBuilder private var cue: some View {
        if let suggestion = coordinator.liveSuggestions.first, !suggestion.isEmpty {
            LiveSuggestionCard(suggestion: suggestion, isLatest: true,
                               style: .teleprompter, tick: Int(coordinator.elapsed))
        } else {
            HStack(spacing: 8) {
                Image(systemName: coordinator.isSuggesting ? "ellipsis" : "waveform")
                    .foregroundStyle(Theme.textTertiary)
                    .symbolEffect(.variableColor.iterative, isActive: coordinator.isSuggesting)
                Text(coordinator.isSuggesting
                     ? "Thinking…"
                     : "Listening. A cue shows up here when you're asked something.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text(timeString(coordinator.elapsed))
                .font(.system(.subheadline).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            LiveWaveform(level: coordinator.audioLevel)
                .frame(width: 56, height: 16)
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showNotes.toggle() }
            } label: {
                Image(systemName: showNotes ? "note.text.badge.plus" : "note.text")
            }
            .buttonStyle(.plain)
            .help(showNotes ? "Hide notes" : "Jot a private note")
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
        .font(.callout)
        .foregroundStyle(Theme.textTertiary)
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
