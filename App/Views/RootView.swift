import SwiftUI

/// Decides what the app shows: sign-in, first-run onboarding, or the tabs.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch appState.phase {
            case .restoring, .loadingProfile:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            case .signedOut:
                AuthView()
                    .trackScreen("Sign in")
            case .profileFailed(let message):
                ContentUnavailableView {
                    Label("Couldn't load your account", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await appState.loadProfile() } }
                        .buttonStyle(.borderedProminent)
                    Button("Sign out") { Task { await appState.signOut() } }
                }
            case .ready:
                if appState.needsOnboarding {
                    OnboardingView()
                        .trackScreen("Onboarding")
                        .id(appState.userId)
                } else {
                    // A fresh set of tabs for each account, so nothing one person
                    // typed (an unsent draft, say) carries over to the next person
                    // to sign in on this device.
                    MainTabs()
                        .id(appState.userId)
                }
            }
        }
        .animation(.default, value: appState.phase)
        .task { await appState.observeAuth() }
        .task(id: sessionKey) { await syncStores() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, appState.phase == .ready else { return }
            Task { await stores.refresh() }
        }
        .onOpenURL { url in
            // Completes email-confirmation links (<url scheme>://auth-callback).
            Task { try? await supabase.auth.session(from: url) }
        }
    }

    /// Changes whenever the signed-in account or its role changes.
    private var sessionKey: String {
        guard appState.phase == .ready, let userId = appState.userId else { return "signed-out" }
        return "\(userId.uuidString)-\(appState.isAdmin)"
    }

    private func syncStores() async {
        if appState.phase == .ready, let userId = appState.userId {
            Analytics.identify(
                userId: userId,
                name: appState.profile?.displayName ?? "",
                isCreator: appState.isAdmin)
            await stores.begin(userId: userId, isAdmin: appState.isAdmin)
        } else if appState.phase == .signedOut {
            Analytics.signedOut()
            await stores.end()
            router.tab = .feed
        }
    }
}
