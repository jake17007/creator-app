import SwiftUI

/// The member's goals: the context the agent and the creator use to help them.
struct GoalsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores

    @State private var adding = false
    @State private var editing: Goal?

    private var store: GoalsStore { stores.goals }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(Creator.agentName) uses these to make its advice about you, and \(Creator.name) can see them when replying to you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }

                if !store.active.isEmpty {
                    Section("Working on") {
                        ForEach(store.active) { goal in
                            row(for: goal)
                        }
                    }
                }

                if !store.done.isEmpty {
                    Section("Finished") {
                        ForEach(store.done) { goal in
                            row(for: goal)
                        }
                    }
                }
            }
            .overlay {
                if store.goals.isEmpty && store.hasLoaded {
                    ContentUnavailableView {
                        Label("No goals yet", systemImage: "target")
                    } description: {
                        Text("Add what you're working toward. One sentence is enough.")
                    } actions: {
                        Button("Add a goal") { adding = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.fill)
                    }
                } else if !store.hasLoaded && store.errorMessage == nil {
                    ProgressView()
                }
            }
            .refreshable {
                if let userId = appState.userId { await store.load(for: userId) }
            }
            .navigationTitle("Goals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a goal")
                }
            }
            .sheet(isPresented: $adding) {
                GoalEditor(goal: nil)
            }
            .sheet(item: $editing) { goal in
                GoalEditor(goal: goal)
            }
        }
    }

    private func row(for goal: Goal) -> some View {
        Button {
            editing = goal
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: goal.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(goal.status == .done ? Theme.accent : Color(.tertiaryLabel))
                    .onTapGesture {
                        Task { await store.setStatus(goal.status == .done ? .active : .done, for: goal) }
                    }
                    .accessibilityLabel(goal.status == .done ? "Mark as not finished" : "Mark as finished")
                    .accessibilityAddTraits(.isButton)

                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.title)
                        .foregroundStyle(goal.status == .done ? .secondary : .primary)
                        .strikethrough(goal.status == .done, color: .secondary)
                        .multilineTextAlignment(.leading)
                    if !goal.details.trimmed.isEmpty {
                        Text(goal.details)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let target = goal.target, goal.status == .active {
                        Label(target.formatted(.dateTime.month(.abbreviated).day().year()), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .privateContent()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await store.delete(goal) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await store.setStatus(goal.status == .done ? .active : .done, for: goal) }
            } label: {
                Label(goal.status == .done ? "Reopen" : "Finished",
                      systemImage: goal.status == .done ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(Theme.fill)
        }
    }
}

/// Add a goal, or edit / finish / delete an existing one.
struct GoalEditor: View {
    let goal: Goal?

    @Environment(Stores.self) private var stores
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var hasTarget = false
    @State private var target = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var isDone = false
    @State private var isSaving = false
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to get done?", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($titleFocused)
                        .privateContent()
                } header: {
                    Text("Goal")
                }

                Section {
                    TextField("Why it matters, where you're stuck", text: $details, axis: .vertical)
                        .lineLimit(3...8)
                        .privateContent()
                } header: {
                    Text("Context (optional)")
                } footer: {
                    Text("The more \(Creator.agentName) and \(Creator.name) know here, the more specific the help.")
                }

                Section {
                    Toggle("Target date", isOn: $hasTarget)
                    if hasTarget {
                        DatePicker("By", selection: $target, displayedComponents: [.date])
                    }
                }

                if goal != nil {
                    Section {
                        Toggle("Finished", isOn: $isDone)
                    }
                    Section {
                        Button("Delete goal", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(goal == nil ? "New goal" : "Edit goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(title.trimmed.isEmpty || isSaving)
                }
            }
            .confirmationDialog("Delete this goal?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let goal else { return }
                    Task {
                        await stores.goals.delete(goal)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                if let goal {
                    title = goal.title
                    details = goal.details
                    isDone = goal.status == .done
                    if let date = goal.target {
                        hasTarget = true
                        target = date
                    }
                } else {
                    titleFocused = true
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let fields = GoalFields(
            title: String(title.trimmed.prefix(140)),
            details: String(details.trimmed.prefix(2000)),
            status: isDone ? .done : .active,
            targetDate: hasTarget ? DayFormat.string(from: target) : nil
        )
        let saved: Bool
        if let goal {
            saved = await stores.goals.update(goal, with: fields)
        } else {
            saved = await stores.goals.add(fields)
        }
        if saved { dismiss() }
    }
}
