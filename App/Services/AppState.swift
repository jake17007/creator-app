import Foundation
import Observation
import Supabase

/// Who is signed in, and their profile. Owns every auth action.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case restoring          // reading the saved session
        case signedOut
        case loadingProfile
        case profileFailed(String)
        case ready
    }

    private(set) var phase: Phase = .restoring
    private(set) var session: Session?
    private(set) var profile: Profile?

    var userId: UUID? { session?.user.id }
    var email: String? { session?.user.email }
    var isAdmin: Bool { profile?.isAdmin ?? false }
    var needsOnboarding: Bool { profile?.onboardedAt == nil }

    // MARK: Session lifecycle

    /// Runs for the lifetime of the app, mirroring Supabase's auth state.
    func observeAuth() async {
        for await (event, session) in supabase.auth.authStateChanges {
            switch event {
            case .initialSession:
                if let session, session.isExpired {
                    // Saved session is stale: try to renew it before deciding.
                    let renewed = try? await supabase.auth.refreshSession()
                    await apply(renewed)
                } else {
                    await apply(session)
                }
            case .signedIn, .tokenRefreshed, .userUpdated:
                await apply(session)
            case .signedOut:
                await apply(nil)
            default:
                break
            }
        }
    }

    private func apply(_ newSession: Session?) async {
        let previousUser = session?.user.id
        session = newSession
        guard let newSession else {
            profile = nil
            phase = .signedOut
            return
        }
        if previousUser != newSession.user.id || profile == nil {
            await loadProfile()
        }
    }

    func loadProfile() async {
        guard let userId else { return }
        if profile == nil { phase = .loadingProfile }
        do {
            // Covers the rare account that has no profile row yet.
            try await supabase.rpc("ensure_profile").execute()
            let loaded: Profile = try await supabase
                .from("profiles")
                .select("id, display_name, is_admin, onboarded_at")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            profile = loaded
            phase = .ready
        } catch let error as PostgrestError where error.code == "23503" {
            // The account was deleted (on another phone, say) while this one
            // was still signed in. There is nothing to load, so sign out.
            await signOut()
        } catch {
            if profile == nil { phase = .profileFailed(friendlyMessage(error)) }
        }
    }

    // MARK: Signing in

    /// Returns a message when the account exists but can't be used yet
    /// (email confirmation pending); nil when the member is now signed in.
    func signUp(email: String, password: String, name: String) async throws -> String? {
        let response = try await supabase.auth.signUp(
            email: email,
            password: password,
            data: ["display_name": .string(name)]
        )
        if response.session == nil {
            return "Check \(email) for a confirmation link, then come back and sign in."
        }
        return nil
    }

    func signIn(email: String, password: String) async throws {
        _ = try await supabase.auth.signIn(email: email, password: password)
    }

    /// Native Sign in with Apple: exchange Apple's identity token for a session.
    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws {
        _ = try await supabase.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
        // Apple only hands over the name on the very first authorization.
        if let fullName, !fullName.isEmpty {
            await loadProfileIfNeeded()
            if profile?.displayName.isEmpty ?? false {
                try? await updateName(fullName)
            }
        }
    }

    private func loadProfileIfNeeded() async {
        if profile == nil { await loadProfile() }
    }

    func signOut() async {
        do {
            try await supabase.auth.signOut()
        } catch {
            // Offline, or the account no longer exists server-side: still
            // forget the session on this device.
            try? await supabase.auth.signOut(scope: .local)
        }
        if session != nil { await apply(nil) }
    }

    /// Permanently deletes the account server-side, then clears the session.
    func deleteAccount() async throws {
        do {
            try await supabase.functions.invoke(Backend.deleteAccountFunction)
        } catch let FunctionsError.httpError(_, data) {
            struct Failure: Decodable { let message: String? }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            throw AppError(message ?? "Couldn't delete the account. Try again.")
        }
        await signOut()
    }

    // MARK: Profile edits

    func updateName(_ name: String) async throws {
        guard let userId else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        try await supabase
            .from("profiles")
            .update(["display_name": trimmed])
            .eq("id", value: userId.uuidString)
            .execute()
        profile?.displayName = trimmed
    }

    func finishOnboarding() async {
        guard let userId else { return }
        let now = Date.now
        profile?.onboardedAt = now
        _ = try? await supabase
            .from("profiles")
            .update(["onboarded_at": ISO8601DateFormatter().string(from: now)])
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Redeems a one-time creator code. True when this account is now an admin.
    func claimCreatorAccess(code: String) async throws -> Bool {
        let granted: Bool = try await supabase
            .rpc("claim_admin", params: ["code": code])
            .execute()
            .value
        if granted { await loadProfile() }
        return granted
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
