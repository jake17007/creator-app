import SwiftUI

// MARK: - Member: their thread with the real creator

struct MemberThreadView: View {
    @Environment(Stores.self) private var stores

    var body: some View {
        NavigationStack {
            Group {
                if let thread = stores.direct {
                    ThreadView(thread: thread, placeholder: "Message \(Creator.name)") {
                        MemberThreadIntro()
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(Creator.name).font(.headline)
                        Text("The real one")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct MemberThreadIntro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CreatorAvatar(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Creator.name).font(.headline)
                    Text("Just the two of you").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("This goes straight to \(Creator.name), not the AI. \(Creator.name) reads every message and can see your goals, so the reply is about what you're working on. It won't be instant. For a quick answer, ask \(Creator.agentName).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared thread UI (member side and creator side)

struct ThreadView<Intro: View>: View {
    @Bindable var thread: DirectStore
    var placeholder: String
    @ViewBuilder var intro: () -> Intro

    @State private var draft = ""

    var body: some View {
        ChatScroll(followKey: thread.messages.count) {
            if thread.messages.isEmpty && thread.hasLoaded {
                intro()
            } else if !thread.hasLoaded {
                ProgressView().padding(.top, 60)
            }

            ForEach(Array(thread.messages.enumerated()), id: \.element.id) { index, message in
                if index == 0 || !Calendar.current.isDate(
                    message.createdAt, inSameDayAs: thread.messages[index - 1].createdAt) {
                    DayDivider(date: message.createdAt)
                }
                ChatBubble(text: message.body, isMine: thread.isMine(message))
            }

            if let last = thread.messages.last, thread.isMine(last) {
                Text(last.readAt == nil ? "Sent" : "Read")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let message = thread.errorMessage {
                    NoticeBar(text: message) { thread.errorMessage = nil }
                }
                ComposerBar(text: $draft, placeholder: placeholder, isBusy: thread.isSending, onSend: send)
            }
        }
        .onAppear { thread.isOnScreen = true }
        .onDisappear { thread.isOnScreen = false }
    }

    private func send() {
        let text = draft
        guard !text.trimmed.isEmpty else { return }
        draft = ""
        Task {
            // Hand the text back if it didn't go through.
            let sent = await thread.send(text)
            if !sent, draft.trimmed.isEmpty { draft = text }
        }
    }
}

// MARK: - Creator: inbox of every member thread

struct InboxView: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores

    var body: some View {
        NavigationStack {
            List {
                if let message = stores.inbox.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                ForEach(stores.inbox.threads) { summary in
                    NavigationLink(value: summary) {
                        InboxRow(summary: summary)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if stores.inbox.threads.isEmpty && stores.inbox.hasLoaded && stores.inbox.errorMessage == nil {
                    ContentUnavailableView {
                        Label("No messages yet", systemImage: "tray")
                    } description: {
                        Text("When a member messages you from their \(Creator.name) tab, the conversation shows up here.")
                    }
                } else if !stores.inbox.hasLoaded && stores.inbox.errorMessage == nil {
                    ProgressView()
                }
            }
            .refreshable { await stores.inbox.load() }
            .navigationTitle("Inbox")
            .navigationDestination(for: ThreadSummary.self) { summary in
                if let myId = appState.userId {
                    CreatorThreadView(summary: summary, myId: myId)
                }
            }
        }
    }
}

private struct InboxRow: View {
    let summary: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(summary.unread > 0 ? Theme.fill : Color.clear)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(summary.title)
                        .font(.body.weight(summary.unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    Text(summary.lastAt.feedStamp)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text((summary.lastFromMember ? "" : "You: ") + summary.lastBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if summary.activeGoals > 0 {
                    Text("\(summary.activeGoals) active goal\(summary.activeGoals == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .privateContent()
    }
}

/// One member's thread, as the creator sees it, with their goals a tap away.
private struct CreatorThreadView: View {
    let summary: ThreadSummary

    @Environment(Stores.self) private var stores
    @State private var thread: DirectStore
    @State private var showingGoals = false

    init(summary: ThreadSummary, myId: UUID) {
        self.summary = summary
        _thread = State(initialValue: DirectStore(threadId: summary.memberId, myId: myId))
    }

    var body: some View {
        ThreadView(thread: thread, placeholder: "Reply to \(summary.title)") {
            EmptyView()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A member's name: hidden in screen recordings like the rest of their thread.
            ToolbarItem(placement: .principal) {
                Text(summary.title).font(.headline).privateContent()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingGoals = true
                } label: {
                    Label("Goals", systemImage: "target")
                }
            }
        }
        .sheet(isPresented: $showingGoals) {
            MemberGoalsSheet(summary: summary)
        }
        .task {
            await thread.start()
            await stores.inbox.load()   // their unread count just dropped
        }
        .onDisappear {
            Task {
                await thread.stop()
                await stores.inbox.load()
            }
        }
    }
}

/// What this member is working toward — the context the creator replies with.
private struct MemberGoalsSheet: View {
    let summary: ThreadSummary

    @Environment(Stores.self) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var goals: [Goal]?

    var body: some View {
        NavigationStack {
            List {
                if let goals {
                    let active = goals.filter { $0.status == .active }
                    let done = goals.filter { $0.status == .done }
                    if goals.isEmpty {
                        Text("They haven't added any goals yet.")
                            .foregroundStyle(.secondary)
                    }
                    if !active.isEmpty {
                        Section("Working on") {
                            ForEach(active) { GoalSummaryRow(goal: $0) }
                        }
                    }
                    if !done.isEmpty {
                        Section("Finished") {
                            ForEach(done) { GoalSummaryRow(goal: $0) }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("\(summary.title)'s goals").font(.headline).privateContent()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { goals = await stores.inbox.goals(for: summary.memberId) }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct GoalSummaryRow: View {
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(goal.title)
            if !goal.details.trimmed.isEmpty {
                Text(goal.details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let target = goal.target {
                Text("Target \(target.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .privateContent()
    }
}
