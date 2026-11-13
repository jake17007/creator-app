import SwiftUI

/// Account settings. The creator account also gets "Teach <agent>" here.
struct YouView: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores

    @State private var name = ""
    @State private var savedName = ""
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var versionTaps = 0
    @State private var showingCreatorAccess = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Your name", text: $name)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .onSubmit { Task { await saveName() } }
                            .privateContent()
                        if name.trimmed != savedName {
                            Button("Save") { Task { await saveName() } }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let email = appState.email {
                        LabeledContent("Email", value: email)
                            .privateContent()
                    }
                } header: {
                    Text("Account")
                } footer: {
                    if !appState.isAdmin {
                        Text("Your name is what \(Creator.name) sees on your messages.")
                    }
                }

                if appState.isAdmin {
                    Section {
                        NavigationLink {
                            NotesView()
                        } label: {
                            Label("Teach \(Creator.agentName)", systemImage: "text.book.closed")
                        }
                    } header: {
                        Text("Creator")
                    } footer: {
                        Text("You're signed in as the creator: you can post to the feed and you see every member's messages.")
                    }
                }

                Section {
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "mailto:\(Backend.supportEmail)")!) {
                        Label("Contact support", systemImage: "envelope")
                    }
                }

                Section {
                    Button("Sign out") { Task { await appState.signOut() } }
                    if !appState.isAdmin {
                        Button("Delete account", role: .destructive) { confirmingDelete = true }
                            .disabled(isDeleting)
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text(version)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Hidden door for the creator: five taps on the version.
                            guard !appState.isAdmin else { return }
                            versionTaps += 1
                            if versionTaps >= 5 {
                                versionTaps = 0
                                showingCreatorAccess = true
                            }
                        }
                }
            }
            .navigationTitle("You")
            .onAppear {
                savedName = appState.profile?.displayName ?? ""
                name = savedName
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { Task { await deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account, your goals, your \(Creator.agentName) conversation, and your messages with \(Creator.name). It can't be undone.")
            }
            .sheet(isPresented: $showingCreatorAccess) {
                CreatorAccessSheet()
            }
        }
    }

    private func saveName() async {
        do {
            try await appState.updateName(name)
            savedName = appState.profile?.displayName ?? name.trimmed
            name = savedName
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await appState.deleteAccount()
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }
}

/// Redeems the one-time code that turns an account into the creator account.
private struct CreatorAccessSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Creator code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .privateContent()
                } footer: {
                    Text(message ?? "Enter the one-time code to make this the creator account. It works once.")
                        .foregroundStyle(message == nil ? Color.secondary : Color.red)
                }
                Section {
                    Button {
                        Task { await redeem() }
                    } label: {
                        if isChecking { ProgressView() } else { Text("Unlock") }
                    }
                    .disabled(code.trimmed.count < 8 || isChecking)
                }
            }
            .navigationTitle("Creator access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func redeem() async {
        isChecking = true
        defer { isChecking = false }
        do {
            if try await appState.claimCreatorAccess(code: code) {
                dismiss()
            } else {
                message = "That code isn't valid, or it has already been used."
            }
        } catch {
            message = friendlyMessage(error)
        }
    }
}

// MARK: - Teach the agent (creator only)

struct NotesView: View {
    @Environment(Stores.self) private var stores

    @State private var adding = false
    @State private var editing: AgentNote?

    private var store: NotesStore { stores.notes }

    var body: some View {
        List {
            Section {
                Text("Everything here becomes part of what \(Creator.agentName) knows about you. Write it the way you'd tell a friend: what you're building right now, what you believe, how you'd answer the questions you get all the time. It only says things about your life that are written here or in the feed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }

            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }

            Section {
                ForEach(store.notes) { note in
                    Button {
                        editing = note
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title).foregroundStyle(.primary)
                            Text(note.content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await store.delete(note) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .overlay {
            if store.notes.isEmpty && store.hasLoaded {
                ContentUnavailableView {
                    Label("Nothing taught yet", systemImage: "text.book.closed")
                } description: {
                    Text("Until you add notes, \(Creator.agentName) only knows your public basics and what's in the feed.")
                } actions: {
                    Button("Add a note") { adding = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.fill)
                }
            }
        }
        .navigationTitle("Teach \(Creator.agentName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a note")
            }
        }
        .sheet(isPresented: $adding) { NoteEditor(note: nil) }
        .sheet(item: $editing) { note in NoteEditor(note: note) }
        .trackScreen("Teach \(Creator.agentName)")
        .task { await store.load() }
    }
}

private struct NoteEditor: View {
    let note: AgentNote?

    @Environment(Stores.self) private var stores
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var content = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Topic") {
                    TextField("e.g. What I'm building right now", text: $title)
                }
                Section("What \(Creator.agentName) should know") {
                    TextField("Write it in your own words", text: $content, axis: .vertical)
                        .lineLimit(8...24)
                }
            }
            .navigationTitle(note == nil ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(title.trimmed.isEmpty || content.trimmed.isEmpty || isSaving)
                }
            }
            .onAppear {
                title = note?.title ?? ""
                content = note?.content ?? ""
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let fields = AgentNoteFields(
            title: String(title.trimmed.prefix(120)),
            content: String(content.trimmed.prefix(8000)))
        if await stores.notes.save(fields, replacing: note) { dismiss() }
    }
}

// MARK: - Privacy policy (the text itself is in PrivacyPolicy.swift)

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Last updated \(PrivacyPolicy.lastUpdated)")
                    .foregroundStyle(.secondary)
                Text(PrivacyPolicy.introduction)
                ForEach(PrivacyPolicy.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).fontWeight(.semibold)
                        Text(section.body).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
        .trackScreen("Privacy Policy")
    }
}
