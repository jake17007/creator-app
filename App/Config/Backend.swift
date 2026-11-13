import Foundation

/// Where the app's backend lives. The values come from `Creator`, which
/// ./configure writes from creator/app.json.
///
/// Everything the app owns in the Supabase project carries the namespace (the
/// schema, the media bucket, the edge functions), so it never mixes with
/// anything else that lives in the same project.
enum Backend {
    static let url: URL = {
        #if DEBUG
        // Point a debug build at another backend, such as a local `supabase start`:
        //   SIMCTL_CHILD_BACKEND_URL=http://127.0.0.1:54321 xcrun simctl launch …
        if let override = ProcessInfo.processInfo.environment["BACKEND_URL"],
           let url = URL(string: override) {
            return url
        }
        #endif
        // A copy with no backend yet still has to launch; sign-in simply fails.
        return URL(string: Creator.backendURL) ?? URL(string: "https://backend-not-set-up.invalid")!
    }()

    /// The project's publishable key. Safe to ship: data access is protected
    /// by row-level security, not by this key.
    static let publishableKey: String = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BACKEND_KEY"], !override.isEmpty {
            return override
        }
        #endif
        return Creator.publishableKey.isEmpty ? "not-set-up" : Creator.publishableKey
    }()

    static let schema = Creator.namespace
    static let mediaBucket = "\(Creator.namespace)-media"
    static let agentFunction = "\(Creator.namespace)-agent"
    static let deleteAccountFunction = "\(Creator.namespace)-delete-account"

    static let privacyURL = url.appendingPathComponent("functions/v1/\(Creator.namespace)-privacy")
    static let supportEmail = Creator.contactEmail
    static let authRedirect = URL(string: "\(Creator.urlScheme)://auth-callback")!
}
