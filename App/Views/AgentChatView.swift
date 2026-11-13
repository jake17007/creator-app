import SwiftUI

/// The conversation with the agent, the AI version of the creator.
struct AgentChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores

    @State private var draft = ""
    @State private var confirmingClear = false

    private var agent: AgentStore { stores.agent }

    /// Bumps whenever something is appended, so the list follows the newest text.
    private var followKey: Int {
        agent.messages.count * 100_000 + agent.streamingText.count + (agent.isResponding ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            ChatScroll(followKey: followKey) {
                intro

                ForEach(Array(agent.messages.enumerated()), id: \.element.id) { index, message in
                    if index == 0 || !Calendar.current.isDate(
                        message.createdAt, inSameDayAs: agent.messages[index - 1].createdAt) {
                        DayDivider(date: message.createdAt)
                    }
                    if message.role == .user, message.postId != nil {
                        AboutPostTag(post: post(for: message.postId))
                    }
                    ChatBubble(text: message.content, isMine: message.role == .user)
                }

                if agent.isResponding {
                    if agent.streamingText.isEmpty {
                        TypingBubble()
                    } else {
                        ChatBubble(text: agent.streamingText, isMine: false)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let notice = agent.notice {
                        NoticeBar(text: notice) { agent.notice = nil }
                    }
                    if let post = agent.aboutPost {
                        AskingAboutBar(post: post) { agent.aboutPost = nil }
                    }
                    ComposerBar(
                        text: $draft,
                        placeholder: "Message \(Creator.agentName)",
                        isBusy: agent.isResponding,
                        onSend: send
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(Creator.agentName).font(.headline)
                        Text("AI version of \(Creator.name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            confirmingClear = true
                        } label: {
                            Label("Clear conversation", systemImage: "trash")
                        }
                        .disabled(agent.messages.isEmpty || agent.isResponding)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation options")
                }
            }
            .confirmationDialog("Clear this conversation?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    guard let userId = appState.userId else { return }
                    Task { await agent.clear(for: userId) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(Creator.agentName) forgets everything you've said here. Your goals stay.")
            }
            .onChange(of: agent.restoredDraft) { _, restored in
                // A send failed before it was saved: give the text back.
                if let restored {
                    if draft.trimmed.isEmpty { draft = restored }
                    agent.restoredDraft = nil
                }
            }
        }
    }

    /// Shown at the top of an empty conversation.
    @ViewBuilder
    private var intro: some View {
        if agent.messages.isEmpty && !agent.isResponding && agent.hasLoaded {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    CreatorAvatar(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Creator.agentName).font(.headline)
                        Text("AI version of \(Creator.name)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text("I'm an AI that talks like \(Creator.name) and knows your goals and everything in the feed. I'm not the real \(Creator.name), and I can be wrong. The real one is in the \(appState.isAdmin ? "Inbox" : Creator.name) tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.starters, id: \.self) { starter in
                        Button {
                            draft = starter
                            send()
                        } label: {
                            Text(starter)
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !agent.hasLoaded {
            ProgressView().padding(.top, 60)
        }
    }

    private static let starters = [
        "What should I work on today?",
        "What have you posted lately?",
        "Help me break one of my goals into steps",
    ]

    private func post(for id: UUID?) -> Post? {
        guard let id else { return nil }
        return stores.feed.posts.first { $0.id == id }
    }

    private func send() {
        guard let userId = appState.userId else { return }
        let text = draft
        guard !text.trimmed.isEmpty, !agent.isResponding else { return }
        draft = ""
        Task { await agent.send(text, userId: userId) }
    }
}

/// Small label above a message that was sent about a feed post.
private struct AboutPostTag: View {
    let post: Post?

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Label(snippet, systemImage: "newspaper")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, 4)
    }

    private var snippet: String {
        guard let post else { return "About a post" }
        let text = post.body.trimmed.isEmpty ? (post.linkTitle ?? "a post") : post.body.trimmed
        return "About: \(text.prefix(40))\(text.count > 40 ? "…" : "")"
    }
}

/// Above the composer while the next message is about a specific post.
private struct AskingAboutBar: View {
    let post: Post
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "newspaper")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Asking about this post")
                    .font(.caption.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Stop asking about this post")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var summary: String {
        if !post.body.trimmed.isEmpty { return post.body.trimmed }
        return post.linkTitle ?? post.linkURL ?? "A post from the feed"
    }
}
