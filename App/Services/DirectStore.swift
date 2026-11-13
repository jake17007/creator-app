import Foundation
import Observation
import Supabase

/// One 1:1 thread between a member and the creator. Members hold a single instance
/// for their own thread; the creator opens one per member from the inbox.
@MainActor
@Observable
final class DirectStore {
    let threadId: UUID
    let myId: UUID

    private(set) var messages: [DirectMessage] = []
    private(set) var hasLoaded = false
    private(set) var isSending = false
    var errorMessage: String?

    /// Set by the screen while the thread is on display, so incoming messages
    /// are marked read instead of counted as unread.
    var isOnScreen = false {
        didSet { if isOnScreen && unread > 0 { Task { await markRead() } } }
    }

    private var channel: RealtimeChannelV2?
    private var listener: Task<Void, Never>?

    private static let columns = "id, thread_user_id, sender_id, body, created_at, read_at"

    init(threadId: UUID, myId: UUID) {
        self.threadId = threadId
        self.myId = myId
    }

    /// Messages from the other side that haven't been read here yet.
    var unread: Int {
        messages.filter { $0.senderId != myId && $0.readAt == nil && isIncoming($0) }.count
    }

    func isMine(_ message: DirectMessage) -> Bool { message.senderId == myId }

    /// For the creator, "incoming" means written by the member; for a member,
    /// anything they didn't write themselves.
    private func isIncoming(_ message: DirectMessage) -> Bool {
        threadId == myId ? message.senderId != myId : message.isFromMember
    }

    // MARK: Lifecycle

    func start() async {
        await load()
        await subscribe()
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        if let channel {
            await supabase.removeChannel(channel)
            self.channel = nil
        }
    }

    func load() async {
        do {
            let latest: [DirectMessage] = try await supabase
                .from("dm_messages")
                .select(Self.columns)
                .eq("thread_user_id", value: threadId.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value
            messages = latest.reversed()
            hasLoaded = true
            errorMessage = nil
            if isOnScreen && unread > 0 { await markRead() }
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    private func subscribe() async {
        guard channel == nil else { return }
        let thread = threadId.uuidString.lowercased()
        let channel = supabase.channel("\(Creator.namespace)-dm-\(thread)")
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: Backend.schema,
            table: "dm_messages",
            filter: .eq("thread_user_id", value: thread)
        )
        self.channel = channel
        // If the live connection can't be opened, messages still arrive on the next load.
        try? await channel.subscribeWithError()
        listener = Task { [weak self] in
            for await insert in inserts {
                guard let message = try? insert.decodeRecord(as: DirectMessage.self, decoder: .backend) else {
                    // Couldn't read the pushed row; fall back to a reload.
                    await self?.load()
                    continue
                }
                await self?.receive(message)
            }
        }
    }

    private func receive(_ message: DirectMessage) async {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
        if isOnScreen && !isMine(message) { await markRead() }
    }

    // MARK: Actions

    @discardableResult
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let sent: DirectMessage = try await supabase
                .from("dm_messages")
                .insert(DirectMessageInsert(threadUserId: threadId, body: String(trimmed.prefix(4000))))
                .select(Self.columns)
                .single()
                .execute()
                .value
            if !messages.contains(where: { $0.id == sent.id }) { messages.append(sent) }
            errorMessage = nil
            Analytics.event("dm_sent", ["as_creator": threadId != myId])
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    func markRead() async {
        do {
            try await supabase.rpc("mark_thread_read", params: ["thread": threadId.uuidString]).execute()
            let now = Date.now
            for index in messages.indices where !isMine(messages[index]) && messages[index].readAt == nil {
                messages[index].readAt = now
            }
        } catch {
            // Non-fatal: the badge just stays until the next successful attempt.
        }
    }
}

/// The creator's inbox: every member thread, most recent first.
@MainActor
@Observable
final class InboxStore {
    private(set) var threads: [ThreadSummary] = []
    private(set) var hasLoaded = false
    var errorMessage: String?

    var totalUnread: Int { threads.reduce(0) { $0 + $1.unread } }

    private var channel: RealtimeChannelV2?
    private var listener: Task<Void, Never>?

    func start() async {
        await load()
        guard channel == nil else { return }
        let channel = supabase.channel("\(Creator.namespace)-inbox")
        let inserts = channel.postgresChange(InsertAction.self, schema: Backend.schema, table: "dm_messages")
        self.channel = channel
        try? await channel.subscribeWithError()
        listener = Task { [weak self] in
            for await _ in inserts { await self?.load() }
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        if let channel {
            await supabase.removeChannel(channel)
            self.channel = nil
        }
        threads = []
        hasLoaded = false
    }

    func load() async {
        do {
            threads = try await supabase.rpc("admin_threads").execute().value
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// A member's goals, so the creator can see what they're working on while replying.
    func goals(for memberId: UUID) async -> [Goal] {
        let goals: [Goal]? = try? await supabase
            .from("goals")
            .select("id, user_id, title, details, status, target_date, created_at")
            .eq("user_id", value: memberId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
        return goals ?? []
    }
}

/// What the creator has taught the agent about themself (creator only).
@MainActor
@Observable
final class NotesStore {
    private(set) var notes: [AgentNote] = []
    private(set) var hasLoaded = false
    var errorMessage: String?

    private static let columns = "id, title, content, updated_at"

    func load() async {
        do {
            notes = try await supabase
                .from("agent_notes")
                .select(Self.columns)
                .order("created_at", ascending: true)
                .execute()
                .value
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    @discardableResult
    func save(_ fields: AgentNoteFields, replacing existing: AgentNote?) async -> Bool {
        do {
            if let existing {
                let updated: AgentNote = try await supabase
                    .from("agent_notes")
                    .update(fields)
                    .eq("id", value: existing.id.uuidString)
                    .select(Self.columns)
                    .single()
                    .execute()
                    .value
                if let index = notes.firstIndex(where: { $0.id == existing.id }) { notes[index] = updated }
            } else {
                let created: AgentNote = try await supabase
                    .from("agent_notes")
                    .insert(fields)
                    .select(Self.columns)
                    .single()
                    .execute()
                    .value
                notes.append(created)
            }
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    func delete(_ note: AgentNote) async {
        do {
            try await supabase.from("agent_notes").delete().eq("id", value: note.id.uuidString).execute()
            notes.removeAll { $0.id == note.id }
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }
}
