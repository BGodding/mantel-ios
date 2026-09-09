import SwiftUI

struct LoginView: View {
    let repo: SessionRepository
    let initialMessage: String?
    let onAuthenticated: () -> Void

    @State private var username = ""
    @State private var appPassword = ""
    @State private var busy = false
    @State private var error: String?

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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                        .onChange(of: username) { error = nil }

                    SecureField("App password", text: $appPassword)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
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
                    .disabled(busy || username.isEmpty || appPassword.isEmpty)
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
            }
            busy = false
        }
    }
}
