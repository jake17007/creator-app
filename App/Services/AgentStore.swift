import Foundation
import Observation
import Supabase

// MARK: - Talking to the agent edge function

enum AgentEvent {
    /// The member's turn was saved (replaces the optimistic copy).
    case started(AgentMessage)
    case delta(String)
    case done(AgentMessage)
    /// The server gave up cleanly and rolled the member's turn back.
    case failed(String)
}

struct AgentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AgentStream {
    private struct Body: Encodable {
        let message: String
        let postId: UUID?
        let tzOffsetMinutes: Int

        enum CodingKeys: String, CodingKey {
            case message
            case postId = "post_id"
            case tzOffsetMinutes = "tz_offset_minutes"
        }
    }

    private struct Wire: Decodable {
        let type: String
        let text: String?
        let message: Payload?
        let userMessage: AgentMessage?

        enum CodingKeys: String, CodingKey {
            case type, text, message
            case userMessage = "user_message"
        }

        /// `message` is a saved row on "done" and a plain string on "error".
        enum Payload: Decodable {
            case row(AgentMessage)
            case text(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else {
                    self = .row(try container.decode(AgentMessage.self))
                }
            }
        }
    }

    private struct Rejection: Decodable {
        let error: String?
        let message: String?
    }

    /// Sends one message and yields the reply as it is written.
    static func send(message: String, postId: UUID?) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let token = try await supabase.auth.session.accessToken
                    var request = URLRequest(
                        url: Backend.url.appendingPathComponent("functions/v1/\(Backend.agentFunction)"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue(Backend.publishableKey, forHTTPHeaderField: "apikey")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(Body(
                        message: message,
                        postId: postId,
                        tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let rejection = try? JSONDecoder().decode(Rejection.self, from: data)
                        throw AgentFailure(
                            message: rejection?.message ?? "\(Creator.agentName) couldn't answer just now. Try again in a moment.")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder.backend.decode(Wire.self, from: data) else { continue }
                        switch event.type {
                        case "start":
                            if let saved = event.userMessage { continuation.yield(.started(saved)) }
                        case "delta":
                            if let text = event.text { continuation.yield(.delta(text)) }
                        case "done":
                            if case .row(let reply) = event.message { continuation.yield(.done(reply)) }
                        case "error":
                            if case .text(let text) = event.message {
                                continuation.yield(.failed(text))
                            } else {
                                continuation.yield(.failed("\(Creator.agentName) blanked on that one. Try again."))
                            }
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - The conversation

@MainActor
@Observable
final class AgentStore {
    private(set) var messages: [AgentMessage] = []
    private(set) var hasLoaded = false
    /// True from the moment a message is sent until the reply is complete.
    private(set) var isResponding = false
    /// The reply so far, while it is still being written.
    private(set) var streamingText = ""
    /// A one-line problem to show above the composer (limit reached, offline…).
    var notice: String?
    /// The post the next message is about (set by "Ask <agent>" in the feed).
    var aboutPost: Post?
    /// Text handed back to the composer when a send fails before it was saved.
    var restoredDraft: String?

    private static let columns = "id, role, content, post_id, created_at"

    func load(for userId: UUID) async {
        do {
            let latest: [AgentMessage] = try await supabase
                .from("agent_messages")
                .select(Self.columns)
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(80)
                .execute()
                .value
            // Don't clobber a reply that is being written right now.
            if !isResponding { messages = latest.reversed() }
            hasLoaded = true
        } catch {
            if !hasLoaded { notice = friendlyMessage(error) }
        }
    }

    func reset() {
        messages = []
        hasLoaded = false
        isResponding = false
        streamingText = ""
        notice = nil
        aboutPost = nil
        restoredDraft = nil
    }

    func send(_ text: String, userId: UUID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        notice = nil
        let post = aboutPost
        aboutPost = nil
        // The member's turn shows immediately; `turnId` follows it once the
        // server swaps in the saved row.
        var turnId = UUID()
        messages.append(AgentMessage(
            id: turnId, role: .user, content: trimmed, postId: post?.id, createdAt: .now))
        isResponding = true
        streamingText = ""
        Analytics.event("agent_message_sent", ["about_post": post != nil])

        var saved = false
        var finished = false
        do {
            for try await event in AgentStream.send(message: trimmed, postId: post?.id) {
                switch event {
                case .started(let message):
                    saved = true
                    if let index = messages.firstIndex(where: { $0.id == turnId }) {
                        messages[index] = message
                    }
                    turnId = message.id
                case .delta(let text):
                    streamingText += text
                case .done(let reply):
                    finished = true
                    streamingText = ""
                    messages.append(reply)
                case .failed(let message):
                    // Server rolled the turn back: take it out and hand the text back.
                    finished = true
                    streamingText = ""
                    let rolledBack = turnId
                    messages.removeAll { $0.id == rolledBack }
                    notice = message
                    restoredDraft = trimmed
                    aboutPost = post
                }
            }
        } catch {
            notice = (error as? AgentFailure)?.message ?? friendlyMessage(error)
            if !saved {
                let unsent = turnId
                messages.removeAll { $0.id == unsent }
                restoredDraft = trimmed
                aboutPost = post
                finished = true
            }
        }

        isResponding = false
        streamingText = ""
        if !finished {
            // The connection dropped mid-reply. The server keeps writing and
            // saves the result, so pick it up from the database.
            try? await Task.sleep(for: .seconds(2))
            await load(for: userId)
        }
    }

    func clear(for userId: UUID) async {
        do {
            try await supabase
                .from("agent_messages")
                .delete()
                .eq("user_id", value: userId.uuidString)
                .execute()
            messages = []
            notice = nil
        } catch {
            notice = friendlyMessage(error)
        }
    }
}
