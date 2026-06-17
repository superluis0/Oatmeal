import SwiftUI
import AppKit

/// A Spotlight-style floating panel, summoned by a global hotkey from anywhere, to
/// ask a question across all your meetings — answered on-device by the local LLM
/// grounded in your own meeting history. Reuses `MeetingQueryService`.
@MainActor
final class QuickAskController {
    static let shared = QuickAskController()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible { hide() } else { show() }
    }

    func show() {
        if panel == nil {
            let hosting = NSHostingView(rootView: QuickAskView { [weak self] in self?.hide() })
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
                styleMask: [.titled, .fullSizeContentView, .closable],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.contentView = hosting
            panel = p
        }
        guard let panel else { return }
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY + v.height * 0.12))
    }
}

private struct QuickAskView: View {
    var onClose: () -> Void
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false
    @State private var errorText: String?
    @FocusState private var focused: Bool
    @State private var appearance = Appearance.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                TextField("Ask anything about your meetings\u{2026}", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(.title3))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit(ask)
                if asking { ProgressView().controlSize(.small) }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Space.md)

            Divider().overlay(Theme.hairline)

            ScrollView {
                Group {
                    if let errorText {
                        Text(errorText).foregroundStyle(Theme.danger)
                    } else if asking && answer.isEmpty {
                        Text("Thinking\u{2026}").foregroundStyle(Theme.textTertiary)
                    } else if answer.isEmpty {
                        Text("Answers are grounded in your own meetings \u{2014} on-device, nothing leaves your Mac.")
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text(answer).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    }
                }
                .font(.system(.callout))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.md)
        }
        .frame(width: 620, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .fontDesign(appearance.fontDesign)
        .onExitCommand(perform: onClose)
        .onAppear { question = ""; answer = ""; errorText = nil; focused = true }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking, let ctx = AppLifecycle.shared.context else { return }
        asking = true; answer = ""; errorText = nil
        Task {
            defer { asking = false }
            do {
                answer = try await MeetingQueryService(context: ctx).ask(q)
            } catch {
                errorText = "Couldn't answer that \u{2014} is your local AI (LM Studio) running?"
            }
        }
    }
}
