import Foundation
import Supabase

/// The one Supabase client. Its database calls default to the app's own
/// schema (`Backend.schema`), so `supabase.from("goals")` means that schema's
/// `goals` table.
let supabase = SupabaseClient(
    supabaseURL: Backend.url,
    supabaseKey: Backend.publishableKey,
    options: SupabaseClientOptions(
        db: .init(schema: Backend.schema),
        auth: .init(
            redirectToURL: Backend.authRedirect,
            emitLocalSessionAsInitialSession: true
        )
    )
)

extension JSONDecoder {
    /// Decodes Postgres timestamps ("2026-11-13T15:04:05.123456+00:00") as well
    /// as plain ISO-8601, for payloads that don't come through the Supabase
    /// client (the agent's event stream and realtime records).
    static let backend: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = BackendDate.parse(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return decoder
    }()
}

enum BackendDate {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        // Realtime sends "2026-11-13 15:04:05.123456+00" style values.
        let normalized = string.replacingOccurrences(of: " ", with: "T")
        let withZone = normalized.hasSuffix("+00") ? normalized + ":00" : normalized
        return fractional.date(from: withZone) ?? plain.date(from: withZone)
    }
}

/// Turns whatever the backend threw into one sentence a person can act on.
func friendlyMessage(_ error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "You're offline. Check your connection and try again."
        case .timedOut:
            return "That took too long. Try again."
        default:
            return "Couldn't reach the server. Try again."
        }
    }
    let text = error.localizedDescription
    if text.localizedCaseInsensitiveContains("invalid login credentials") {
        return "That email and password don't match an account."
    }
    if text.localizedCaseInsensitiveContains("already registered") {
        return "There's already an account with that email. Sign in instead."
    }
    if text.localizedCaseInsensitiveContains("provider is not enabled")
        || text.localizedCaseInsensitiveContains("unsupported provider") {
        return "That sign-in method isn't switched on yet. Use email for now."
    }
    return text
}
