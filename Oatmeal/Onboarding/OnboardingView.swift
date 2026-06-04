import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var step = 0
    @State private var micGranted = false
    @State private var screenGranted = false
    @State private var calendarGranted = false
    @State private var inputDeviceUID = AppSettings.inputDeviceUID
    @State private var devices = AudioDevices.inputDevices()
    @State private var lmState: LMState = .untested
    @State private var testingLM = false

    private let stepCount = 5

    enum LMState: Equatable { case untested, testing, ok(Int), failed }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            backgroundGlow

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: howItWorksStep
                    case 2: permissionsStep
                    case 3: micStep
                    default: lmStep
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, Theme.Space.xl)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(step)

                Spacer(minLength: 0)
                footer
            }
            .padding(.vertical, Theme.Space.xl)
        }
        .frame(minWidth: 720, minHeight: 600)
        .fontDesign(Appearance.shared.fontDesign)
        .dynamicTypeSize(Appearance.shared.dynamicTypeSize)
        .foregroundStyle(Theme.textPrimary)
    }

    private var backgroundGlow: some View {
        Circle()
            .fill(Theme.accent.opacity(0.18))
            .frame(width: 520, height: 520)
            .blur(radius: 140)
            .offset(y: -200)
            .ignoresSafeArea()
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 108, height: 108)
                .shadow(color: Theme.accent.opacity(0.35), radius: 24, y: 10)
            VStack(spacing: Theme.Space.sm) {
                Text("Welcome to Oatmeal")
                    .font(.system(size: Appearance.shared.scaled(40), weight: .bold))
                Text("Your cozy, on-device meeting notetaker. It listens, transcribes, and writes beautiful notes — all privately on your Mac.")
                    .font(.system(.title3))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OatPill(text: "100% on-device · nothing leaves your Mac", systemImage: "lock.fill")
                .padding(.top, Theme.Space.xs)
        }
    }

    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            stepHeader("How Oatmeal works", "Three steps to effortless notes.")
            VStack(spacing: Theme.Space.sm) {
                featureRow("record.circle.fill", "Record any meeting",
                           "Captures the other people (system audio) and your mic — no bots, no links.")
                featureRow("wand.and.stars", "Notes write themselves",
                           "Jot a few words; the local AI turns them into clean, structured notes.")
                featureRow("bubble.left.and.text.bubble.right.fill", "Ask anything later",
                           "Chat across one meeting or your whole history, with sources.")
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            stepHeader("A few permissions", "Oatmeal only uses these locally. You can change them anytime in System Settings.")
            VStack(spacing: Theme.Space.sm) {
                permissionRow("mic.fill", "Microphone", "To transcribe your voice.",
                              granted: micGranted) { micGranted = await AudioCaptureEngine.requestMicrophoneAccess() }
                permissionRow("rectangle.dashed.badge.record", "Screen Recording", "To capture meeting audio from your speakers.",
                              granted: screenGranted) { screenGranted = await AudioCaptureEngine.requestScreenRecordingAccess() }
                permissionRow("calendar", "Calendar", "Optional — to auto-title meetings and add attendees.",
                              granted: calendarGranted) { calendarGranted = await CalendarService().requestAccess() }
            }
            if screenGranted == false {
                Text("Tip: granting Screen Recording for the first time may require relaunching Oatmeal.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var micStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            stepHeader("Choose your microphone", "Pick the mic that captures your voice. Avoid loopback devices like BlackHole — meeting audio is captured automatically.")
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Picker("", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .onChange(of: inputDeviceUID) { _, new in AppSettings.inputDeviceUID = new }
                Button {
                    devices = AudioDevices.inputDevices()
                } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                    .buttonStyle(OatGhostButton())
            }
            .oatCard()
        }
    }

    private var lmStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            stepHeader("Connect your local AI", "Oatmeal uses LM Studio running on your Mac for summaries and chat. Start it, load a model, then test the connection.")
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    IconBadge(systemName: "cpu", size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LM Studio").font(.system(.headline))
                        Text(AppSettings.baseURL).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    lmStatusView
                }
                Divider().overlay(Theme.hairline)
                Button {
                    Task { await testLM() }
                } label: {
                    Label(testingLM ? "Testing…" : "Test connection", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(OatSecondaryButton())
                .disabled(testingLM)
            }
            .oatCard()
            Text("No LM Studio yet? You can still record and transcribe — summaries just wait until it's running.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    @ViewBuilder
    private var lmStatusView: some View {
        switch lmState {
        case .untested: OatPill(text: "Not tested", systemImage: "circle", tint: Theme.textTertiary)
        case .testing: ProgressView().controlSize(.small)
        case .ok(let n): OatPill(text: "\(n) model\(n == 1 ? "" : "s") loaded", systemImage: "checkmark.circle.fill", tint: Theme.success)
        case .failed: OatPill(text: "Not reachable", systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        }
    }

    // MARK: - Footer / nav

    private var footer: some View {
        VStack(spacing: Theme.Space.md) {
            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Theme.accent : Theme.border)
                        .frame(width: i == step ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: step)
                }
            }
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation(.smooth) { step -= 1 } }
                        .buttonStyle(OatGhostButton())
                }
                Spacer()
                if step < stepCount - 1 {
                    Button(step == 0 ? "Get Started" : "Continue") {
                        withAnimation(.smooth) { step += 1 }
                    }
                    .buttonStyle(OatPrimaryButton())
                } else {
                    Button("Start Using Oatmeal") { onFinish() }
                        .buttonStyle(OatPrimaryButton())
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, Theme.Space.xl)
        }
    }

    // MARK: - Pieces

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(.system(size: Appearance.shared.scaled(30), weight: .bold))
            Text(subtitle)
                .font(.system(.body))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            IconBadge(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.headline))
                Text(subtitle).font(.system(.subheadline)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .oatCard()
    }

    private func permissionRow(_ icon: String, _ title: String, _ subtitle: String,
                               granted: Bool, action: @escaping () async -> Void) -> some View {
        HStack(spacing: Theme.Space.md) {
            IconBadge(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.headline))
                Text(subtitle).font(.system(.subheadline)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.success)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Grant") { Task { await action() } }
                    .buttonStyle(OatSecondaryButton())
            }
        }
        .oatCard()
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: granted)
    }

    private func testLM() async {
        testingLM = true
        lmState = .testing
        defer { testingLM = false }
        do {
            let models = try await LMStudioClient().listModels()
            lmState = .ok(models.count)
        } catch {
            lmState = .failed
        }
    }
}
