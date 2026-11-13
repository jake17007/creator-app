import AuthenticationServices
import CryptoKit
import SwiftUI

/// Sign in with Apple, or email + password.
struct AuthView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @State private var showEmail = false
    @State private var isBusy = false
    @State private var message: String?
    /// The raw nonce for the Apple request in flight (Supabase checks it
    /// against the hashed copy inside Apple's identity token).
    @State private var appleNonce = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                CreatorAvatar(size: 72)
                Text(Creator.appName)
                    .font(.largeTitle.bold())
                Text("My posts before they go anywhere else, an AI version of me that knows your goals, and a direct line to the real one.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.continue) { request in
                    appleNonce = Self.randomNonce()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Self.sha256(appleNonce)
                } onCompletion: { result in
                    Task { await finishApple(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(isBusy)

                Button {
                    showEmail = true
                } label: {
                    Text("Continue with email")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Link("Privacy policy", destination: Backend.privacyURL)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showEmail) {
            EmailAuthSheet()
        }
    }

    private func finishApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                message = "Apple didn't return a sign-in token. Try again."
                return
            }
            let name = credential.fullName.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
            }
            isBusy = true
            message = nil
            defer { isBusy = false }
            do {
                try await appState.signInWithApple(idToken: idToken, nonce: appleNonce, fullName: name)
            } catch {
                message = friendlyMessage(error)
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            message = friendlyMessage(error)
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Email + password, for both creating an account and signing back in.
private struct EmailAuthSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isNewAccount = true
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var message: String?
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    private var canSubmit: Bool {
        let hasEmail = email.trimmed.contains("@")
        return hasEmail && password.count >= 8 && !isBusy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("", selection: $isNewAccount) {
                        Text("Create account").tag(true)
                        Text("Sign in").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 6)

                    if isNewAccount {
                        TextField("Your name", text: $name)
                            .textContentType(.name)
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .email }
                            .fieldStyle()
                            .privateContent()
                    }

                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .fieldStyle()
                        .privateContent()

                    SecureField("Password (8+ characters)", text: $password)
                        .textContentType(isNewAccount ? .newPassword : .password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { Task { await submit() } } }
                        .fieldStyle()
                        .privateContent()

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        if isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Text(isNewAccount ? "Create account" : "Sign in")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit)
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .navigationTitle(isNewAccount ? "Create account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: isNewAccount) { message = nil }
        }
        .presentationDetents([.large])
    }

    private func submit() async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            if isNewAccount {
                if let pending = try await appState.signUp(
                    email: email.trimmed, password: password, name: name.trimmed) {
                    message = pending
                }
            } else {
                try await appState.signIn(email: email.trimmed, password: password)
            }
        } catch {
            message = friendlyMessage(error)
        }
    }
}
