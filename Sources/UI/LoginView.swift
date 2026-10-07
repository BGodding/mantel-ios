import SwiftUI

struct LoginView: View {
    let repo: SessionRepository
    let initialMessage: String?
    let onAuthenticated: () -> Void

    @State private var username = ""
    @State private var appPassword = ""
    @State private var showPassword = false
    @State private var busy = false
    @State private var error: String?

    private var canSubmit: Bool { !busy && !username.isEmpty && !appPassword.isEmpty }

    var body: some View {
        SecureContainer {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Sign in to your frames")
                        .font(.title2).bold()

                    Text("Use an app password, not your Nextcloud login password — "
                        + "ask your admin if you don't have one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .submitLabel(.next)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                        .onChange(of: username) { error = nil }

                    HStack {
                        Group {
                            if showPassword {
                                TextField("App password", text: $appPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("App password", text: $appPassword)
                            }
                        }
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { submit() } }
                        Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                            .font(.callout)
                    }
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                    .disabled(busy)
                    .onChange(of: appPassword) { error = nil }

                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: submit) {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Sign in").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { error = initialMessage }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            switch await repo.logIn(username: username, appPassword: appPassword) {
            case .success:
                onAuthenticated()
            case .invalidCredentials:
                error = Messages.invalidCredentials
            case .unreachable:
                error = Messages.noConnection
            case let .serverProblem(code):
                error = Messages.serverError(code)
            case .storageFailed:
                error = Messages.storageFailed
            }
            busy = false
        }
    }
}
