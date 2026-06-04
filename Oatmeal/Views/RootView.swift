import SwiftUI

/// Routes between first-run onboarding and the main app.
struct RootView: View {
    @Bindable var coordinator: RecordingCoordinator
    var detector: MeetingDetector
    @State private var appearance = Appearance.shared
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some View {
        Group {
            if hasOnboarded {
                ContentView(coordinator: coordinator, detector: detector)
                    .transition(.opacity)
            } else {
                OnboardingView {
                    withAnimation(.smooth(duration: 0.5)) { hasOnboarded = true }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: hasOnboarded)
        .preferredColorScheme(appearance.colorScheme)
    }
}
