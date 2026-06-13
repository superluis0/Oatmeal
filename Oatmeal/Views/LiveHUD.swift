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
            // A slim teleprompter strip near the top of the screen (where your
            // webcam / the other person's face sits), so a glance reads the cue
            // without an obvious eye dart toward a corner panel. The panel is
            // taller than the strip: the extra (fully transparent) area below is
            // where the suggestion drawer slides out, without animating the
            // window frame itself.
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
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

/// The floating panel's contents: a slim glanceable strip (timer, live waveform,
/// controls) with a drawer that slides out beneath it for on-demand cues and notes.
struct LiveHUDView: View {
    let coordinator: RecordingCoordinator
    let context: ModelContext
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Entrance animation state. The HUD "springs into" existence when recording
    // starts, then settles. A one-shot guard keeps it from replaying on
    // re-renders (e.g. when the coordinator/context is re-pointed on show()).
    @State private var didAppear = false

    /// What's expanded beneath the strip. `nil` keeps the HUD a single clean
    /// pill — the resting state now that cues are on-demand only.
    enum Drawer { case suggestion, notes }
    @State private var drawer: Drawer?

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
        VStack(spacing: Theme.Space.xs) {
            strip
                // Above the drawer in z, so mid-transition the drawer slides out
                // from *under* the strip rather than over it.
                .zIndex(1)

            if let drawer {
                drawerView(drawer)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // The panel is taller than the strip (room for the drawer); pin content
        // to its top so the strip sits at a fixed eyeline and only the drawer moves.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .motion(Motion.gentle(reduceMotion), value: drawer)
        .fontDesign(Appearance.shared.fontDesign)
    }

    // MARK: - The strip

    /// The always-visible teleprompter pill: pulsing dot + timer, the live
    /// waveform as the centerpiece, and the three actions.
    private var strip: some View {
        HStack(spacing: Theme.Space.sm) {
            PulsingDot()
            Text(timeString(coordinator.elapsed))
                .font(.system(.subheadline).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())

            LiveWaveform(level: coordinator.audioLevel, style: .hero)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .padding(.horizontal, Theme.Space.xs)

            Button {
                coordinator.markHighlight(context: context)
            } label: {
                Label("Mark", systemImage: "bookmark.fill").lineLimit(1)
            }
            .buttonStyle(OatGhostButton())

            Button(action: requestCue) {
                Label("Suggest", systemImage: "lightbulb.fill").lineLimit(1)
            }
            .buttonStyle(OatSecondaryButton())
            .disabled(coordinator.isSuggesting)

            Button {
                Task { await coordinator.stop(context: context) }
            } label: {
                Label("Stop", systemImage: "stop.fill").lineLimit(1)
            }
            .buttonStyle(OatPrimaryButton(destructive: true))

            utilities
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs + 2)
        // Translucent material (panel is non-opaque) so the strip floats softly over
        // the call instead of reading as a solid app window.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
    }

    private var utilities: some View {
        HStack(spacing: Theme.Space.xs) {
            Button {
                drawer = (drawer == .notes) ? nil : .notes
            } label: {
                Image(systemName: drawer == .notes ? "note.text.badge.plus" : "note.text")
            }
            .help(drawer == .notes ? "Hide notes" : "Jot a private note")
            Button {
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
            }
            .help("Bring Oatmeal's main window forward")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help("Hide the floating panel")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(Theme.textTertiary)
    }

    // MARK: - The drawer

    /// Opens the cue drawer immediately (committing to the gesture), then asks
    /// for the suggestion — the drawer shows a thinking skeleton until it lands.
    private func requestCue() {
        drawer = .suggestion
        Task { await coordinator.requestSuggestion() }
    }

    private func drawerView(_ mode: Drawer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                SectionLabel(text: mode == .notes ? "Notes" : "Cue")
                Spacer()
                Button {
                    drawer = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Dismiss")
            }

            switch mode {
            case .suggestion: suggestionContent
            case .notes: notesContent
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }

    @ViewBuilder private var suggestionContent: some View {
        Group {
            if coordinator.isSuggesting {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "ellipsis")
                            .symbolEffect(.variableColor.iterative, isActive: true)
                        Text("Thinking…")
                    }
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    SkeletonLines(lineWidths: [0.95, 0.8, 0.55])
                }
            } else if let suggestion = coordinator.liveSuggestions.first, !suggestion.isEmpty {
                // Render at natural size when the cue fits; fall back to a
                // scrolling pane for long ones so the drawer never runs off-panel.
                ViewThatFits(in: .vertical) {
                    cueBody(suggestion)
                    ScrollView { cueBody(suggestion) }
                }
                .frame(maxHeight: 280)
            } else {
                Text("No cue right now — try again in a moment.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .motion(Motion.reveal(reduceMotion), value: coordinator.isSuggesting)
        .motion(Motion.reveal(reduceMotion), value: coordinator.liveSuggestions.first?.id)
    }

    private func cueBody(_ suggestion: LiveSuggestion) -> some View {
        LiveSuggestionCard(suggestion: suggestion, isLatest: true,
                           style: .teleprompter, tick: Int(coordinator.elapsed))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notesContent: some View {
        TextEditor(text: notes)
            .font(.system(size: 13 * Appearance.shared.fontScale))
            .scrollContentBackground(.hidden)
            .padding(Theme.Space.xs)
            .frame(height: 140)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
