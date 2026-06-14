import SwiftUI
import SwiftData
import KeyboardShortcuts
import AppKit

struct SettingsView: View {
    @State private var baseURL: String = AppSettings.baseURL
    @State private var model: String = AppSettings.model
    @State private var defaultTemplate: String = AppSettings.defaultTemplate
    @State private var autoDetect: Bool = AppSettings.autoDetectMeetings
    @State private var autoSelectTemplate: Bool = AppSettings.autoSelectTemplate
    @State private var webhookURL: String = AppSettings.webhookURL
    @State private var inputDeviceUID: String = AppSettings.inputDeviceUID
    @State private var inputDevices: [AudioInputDevice] = AudioDevices.inputDevices()
    @State private var preMeetingReminders: Bool = AppSettings.preMeetingReminders
    @State private var syncReminders: Bool = AppSettings.syncReminders
    @State private var modelVersion: String = AppSettings.modelVersion
    @State private var asrEngine: String = AppSettings.asrEngine
    // @AppStorage (not @State) so this stays live-synced with the sidebar's
    // meeting-type picker, which writes the same key.
    @AppStorage("inPersonMode") private var inPersonMode = false
    @State private var retentionDays: Int = AppSettings.audioRetentionDays
    @State private var audioSize: String = StorageManager.formattedAudioSize()
    @State private var liveAssist: Bool = AppSettings.liveAssistEnabled
    @State private var assistProfile: String = AppSettings.assistProfile
    @State private var floatingPanelAuto: Bool = AppSettings.floatingPanelAuto
    @State private var userName: String = AppSettings.userName
    @State private var userTagline: String = AppSettings.userTagline
    @State private var checkForUpdates: Bool = AppSettings.checkForUpdates
    @State private var updateChecker = UpdateChecker.shared
    @State private var backupConfirmed = false
    @Bindable private var appearance = Appearance.shared
    @Environment(\.modelContext) private var modelContext
    @Query private var allMeetings: [Meeting]

    var body: some View {
        Form {
            Section("You") {
                TextField("Your name", text: $userName, prompt: Text("e.g. Alex Rivera"))
                    .onChange(of: userName) { _, new in AppSettings.userName = new }
                TextField("Your role / company (optional)", text: $userTagline, prompt: Text("e.g. PM at Acme"))
                    .onChange(of: userTagline) { _, new in AppSettings.userTagline = new }
                Text("Used so summaries and chat know which speaker is you (\u{201C}Me\u{201D}) and never mix you up with the other participants. Stored locally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance.colorSchemePreference) {
                    ForEach(ColorSchemePreference.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance.colorSchemePreference) { _, _ in appearance.save() }
                Picker("Font", selection: $appearance.fontChoice) {
                    ForEach(FontChoice.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: appearance.fontChoice) { _, _ in appearance.save() }
                Picker("Text size", selection: $appearance.textSize) {
                    ForEach(TextSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance.textSize) { _, _ in appearance.save() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accent").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(AccentChoice.allCases) { choice in
                            Circle()
                                .fill(choice.gradient)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .opacity(appearance.accent == choice ? 1 : 0)
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(appearance.accent == choice ? 0.85 : 0), lineWidth: 2)
                                        .padding(-3)
                                )
                                .contentShape(Circle())
                                .onTapGesture { appearance.accent = choice; appearance.save() }
                                .help(choice.label)
                        }
                    }
                }
                Toggle("Play a chime when recording starts and stops", isOn: $appearance.recordingChime)
                    .onChange(of: appearance.recordingChime) { _, _ in appearance.save() }
            }

            Section("Record button") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Border color").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 10)], spacing: 10) {
                        // Match the current accent.
                        borderSwatch(style: appearance.accent.gradient,
                                     selected: !appearance.recordBorderRainbow
                                        && appearance.recordBorderHex == appearance.accent.color.hexValue) {
                            appearance.recordBorderRainbow = false
                            appearance.recordBorderHex = appearance.accent.color.hexValue
                            appearance.save()
                        }
                        // Rainbow snake.
                        borderSwatch(style: rainbowSwatch, selected: appearance.recordBorderRainbow) {
                            appearance.recordBorderRainbow = true
                            appearance.save()
                        }
                        // Curated presets.
                        ForEach(Appearance.recordBorderPalette, id: \.self) { hex in
                            borderSwatch(style: Color(hex: hex),
                                         selected: !appearance.recordBorderRainbow && appearance.recordBorderHex == hex) {
                                appearance.recordBorderRainbow = false
                                appearance.recordBorderHex = hex
                                appearance.save()
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        recordPreview(label: "New Recording", icon: "record.circle.fill", recording: false)
                        recordPreview(label: "Stop Recording", icon: "stop.fill", recording: true)
                    }
                }
                Text("The border traces your chosen color around the record button, and animates while a recording is in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("LM Studio") {
                TextField("Server URL", text: $baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    .onChange(of: baseURL) { _, new in AppSettings.baseURL = new }
                TextField("Model (optional)", text: $model, prompt: Text("Auto-select first loaded model"))
                    .onChange(of: model) { _, new in AppSettings.model = new }
                Text("Oatmeal sends meeting transcripts to a local LM Studio server for summarization. Start LM Studio and load a model before recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                Picker("Default template", selection: $defaultTemplate) {
                    ForEach(NoteTemplate.builtins) { Text($0.name).tag($0.name) }
                }
                .onChange(of: defaultTemplate) { _, new in AppSettings.defaultTemplate = new }
                Toggle("Auto-select template from transcript", isOn: $autoSelectTemplate)
                    .onChange(of: autoSelectTemplate) { _, new in AppSettings.autoSelectTemplate = new }
            }

            Section("Tasks") {
                Toggle("Sync action items to Apple Reminders", isOn: $syncReminders)
                    .onChange(of: syncReminders) { _, new in
                        AppSettings.syncReminders = new
                        if new {
                            let meetings = allMeetings
                            let ref = ModelContextRef { try? modelContext.save() }
                            Task { await RemindersService.syncAll(meetings: meetings, context: ref) }
                        }
                    }
                Text("Adds open action items to an \u{201C}Oatmeal\u{201D} list in Reminders. Completing a task here completes it there too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live Assist") {
                Toggle("Float a panel over my call while recording", isOn: $floatingPanelAuto)
                    .onChange(of: floatingPanelAuto) { _, new in AppSettings.floatingPanelAuto = new }
                Toggle("Suggest answers while I'm recording", isOn: $liveAssist)
                    .onChange(of: liveAssist) { _, new in AppSettings.liveAssistEnabled = new }
                VStack(alignment: .leading, spacing: 4) {
                    Text("About you").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $assistProfile)
                        .font(.system(.body))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .onChange(of: assistProfile) { _, new in AppSettings.assistProfile = new }
                }
                Text("During a recording, Oatmeal can privately suggest answers and smart follow-up questions when you're asked something. Add your role/background above to personalize them. Everything runs on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Start / stop recording", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Bookmark a moment", name: .markMoment)
                Text("Global hotkeys work from any app — start a recording without leaving your meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { Text($0.name).tag($0.id) }
                }
                .onChange(of: inputDeviceUID) { _, new in AppSettings.inputDeviceUID = new }
                Button("Refresh devices") { inputDevices = AudioDevices.inputDevices() }
                    .font(.caption)
                Text("Pick the mic that captures your voice. Don't choose a loopback device like BlackHole here — meeting audio (other people) is captured automatically via Screen Recording, so the mic should be your actual microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Live captions engine", selection: $asrEngine) {
                    Text("Parakeet (proven)").tag("parakeet")
                    Text("Nemotron streaming (new)").tag("nemotron")
                }
                .onChange(of: asrEngine) { _, new in AppSettings.asrEngine = new }
                Picker("Language model", selection: $modelVersion) {
                    Text("English (fastest)").tag("v2")
                    Text("Multilingual").tag("v3")
                }
                .onChange(of: modelVersion) { _, new in AppSettings.modelVersion = new }
                Toggle("In-person mode (diarize my mic into multiple speakers)", isOn: $inPersonMode)
                Text("Engine changes apply to your next recording. Nemotron is NVIDIA's new streaming model: it runs fully on-device (Apple Silicon), downloads ~0.5 GB on first use, and if it can't start, the recording continues on Parakeet. The final transcript is always polished by the proven pipeline. In-person mode is for meetings where everyone shares your Mac's mic — also switchable right under the record button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("Everything runs on your Mac. Transcription and AI happen locally — your meetings are never uploaded.", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Meetings stored", value: "\(allMeetings.count)")
                LabeledContent("Outbound network") {
                    Text(webhookURL.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "LM Studio (local) only"
                         : "LM Studio + your webhook")
                        .foregroundStyle(.secondary)
                }
                Button("Reveal data folder in Finder") { revealDataFolder() }
                Button("Reveal diagnostic logs") {
                    if let dir = Log.logDirectory {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
                Button("Back up meetings now") {
                    StoreBackup.snapshot(context: modelContext)
                    backupConfirmed = true
                }
                if backupConfirmed {
                    Label("Backup written.", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.accent)
                }
                Text("Oatmeal backs up automatically and restores your meetings if the database is ever reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Archived audio", value: audioSize)
                Picker("Auto-delete audio", selection: $retentionDays) {
                    Text("Never").tag(0)
                    Text("After 30 days").tag(30)
                    Text("After 90 days").tag(90)
                    Text("After 1 year").tag(365)
                }
                .onChange(of: retentionDays) { _, new in AppSettings.audioRetentionDays = new }
                Button("Delete all audio", role: .destructive) {
                    StorageManager.deleteAllAudio(meetings: allMeetings, context: modelContext)
                    audioSize = StorageManager.formattedAudioSize()
                }
                Text("Transcripts, notes, and summaries are always kept — only the audio files are removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting detection") {
                Toggle("Remind me before calendar meetings", isOn: $preMeetingReminders)
                    .onChange(of: preMeetingReminders) { _, new in
                        AppSettings.preMeetingReminders = new
                        Task { await ReminderScheduler.refresh() }
                    }
                Toggle("Suggest recording when a meeting starts", isOn: $autoDetect)
                    .onChange(of: autoDetect) { _, new in AppSettings.autoDetectMeetings = new }
                Text("When on, Oatmeal watches for a video-call app running alongside a live calendar event and offers to start recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Webhook (optional)") {
                TextField("Webhook URL", text: $webhookURL, prompt: Text("https://hooks.slack.com/…"))
                    .onChange(of: webhookURL) { _, new in AppSettings.webhookURL = new }
                Text("When set, Oatmeal POSTs each finished meeting's summary + action items to this URL (Slack-compatible). Leave empty to keep everything local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Current version", value: updateChecker.currentVersion)
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, new in
                        updateChecker.setAutomaticChecks(new)
                        if new { updateChecker.checkForUpdates() }
                    }
                if let update = updateChecker.available {
                    HStack {
                        Label("Version \(update.version) is available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Theme.accent)
                            .updatePulse()
                        Spacer()
                        Button("Install…") { updateChecker.checkForUpdates() }
                    }
                } else {
                    HStack {
                        Button {
                            updateChecker.checkForUpdates()
                        } label: {
                            Label(updateChecker.isChecking ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
                        }
                        .disabled(updateChecker.isChecking)
                        Spacer()
                        Text("You're up to date").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Checks the Oatmeal release feed over HTTPS for a newer version and can install it in one click. No data about you is sent. Turn off to keep Oatmeal fully offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fontDesign(Appearance.shared.fontDesign)
        .dynamicTypeSize(Appearance.shared.dynamicTypeSize)
        .tint(Theme.accent)
        .frame(width: 500, height: 560)
        .navigationTitle("Settings")
    }

    private func revealDataFolder() {
        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Oatmeal", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// A faithful mini record-button: accent gradient fill + chosen (snaking) border.
    private func recordPreview(label: String, icon: String, recording: Bool) -> some View {
        Label(label, systemImage: icon)
            .font(.system(.subheadline).weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                SnakeBorder(color: appearance.recordBorderColor,
                            rainbow: appearance.recordBorderRainbow,
                            cornerRadius: Theme.Radius.md,
                            active: recording)
            )
            .frame(width: 150)
    }

    private var rainbowSwatch: AngularGradient {
        AngularGradient(gradient: Gradient(colors: AccentChoice.rainbowColors + [AccentChoice.rainbowColors[0]]),
                        center: .center)
    }

    private func borderSwatch<S: ShapeStyle>(style: S, selected: Bool, action: @escaping () -> Void) -> some View {
        Circle()
            .fill(style)
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .opacity(selected ? 1 : 0)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(selected ? 0.85 : 0), lineWidth: 2)
                    .padding(-3)
            )
            .contentShape(Circle())
            .onTapGesture(perform: action)
    }
}
