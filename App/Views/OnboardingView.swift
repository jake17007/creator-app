import SwiftUI

/// First run: a name, then a couple of goals. Both are optional, and both are
/// what make the agent's and the creator's replies about this person specifically.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores

    @State private var step = 0
    @State private var name = ""
    @State private var goals = ["", "", ""]
    @State private var isSaving = false
    @FocusState private var focusedGoal: Int?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if step == 0 {
                nameStep
            } else {
                goalsStep
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 48)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
        .onAppear {
            name = appState.profile?.displayName ?? ""
            // Already have a name (Apple gave us one, or they typed it at sign-up).
            if !name.trimmed.isEmpty { step = 1 }
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What should I call you?")
                .font(.title.bold())
            Text("This is the name \(Creator.name) sees on your messages.")
                .foregroundStyle(.secondary)

            TextField("Your name", text: $name)
                .textContentType(.givenName)
                .submitLabel(.continue)
                .focused($nameFocused)
                .onSubmit { Task { await saveName() } }
                .fieldStyle()
                .privateContent()
                .padding(.top, 8)

            Spacer()

            Button("Continue") { Task { await saveName() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving)
        }
        .onAppear { nameFocused = true }
    }

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What are you working toward?")
                .font(.title.bold())
            Text("Add up to three goals. \(Creator.agentName) uses them to give you advice that's about you, and \(Creator.name) can see them when replying to you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(goals.indices, id: \.self) { index in
                    TextField(placeholder(for: index), text: $goals[index], axis: .vertical)
                        .lineLimit(1...3)
                        .focused($focusedGoal, equals: index)
                        .fieldStyle()
                        .privateContent()
                }
            }
            .padding(.top, 8)

            Text("You can change these any time in the Goals tab.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { await finish(saving: true) }
            } label: {
                if isSaving { ProgressView().tint(.white) } else { Text("Continue") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSaving)

            Button("Skip for now") { Task { await finish(saving: false) } }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .disabled(isSaving)
        }
    }

    private func placeholder(for index: Int) -> String {
        switch index {
        case 0: return "e.g. Ship my first app"
        case 1: return "e.g. Post three videos a week"
        default: return "e.g. Get to a 4-hour focus day"
        }
    }

    private func saveName() async {
        isSaving = true
        defer { isSaving = false }
        if !name.trimmed.isEmpty {
            try? await appState.updateName(name)
        }
        nameFocused = false
        withAnimation { step = 1 }
    }

    private func finish(saving: Bool) async {
        isSaving = true
        defer { isSaving = false }
        focusedGoal = nil
        if saving {
            for title in goals.map(\.trimmed) where !title.isEmpty {
                await stores.goals.add(GoalFields(
                    title: String(title.prefix(140)), details: "", status: .active, targetDate: nil))
            }
        }
        await appState.finishOnboarding()
    }
}
