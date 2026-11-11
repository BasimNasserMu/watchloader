import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var editingAddress: Bool
    @State private var showImporter = false
    @State private var pendingKind: AppModel.ImportKind = .phonePairing
    @State private var showSignIn = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    if let account = model.account {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name.isEmpty ? account.email : account.name).font(.headline)
                                Text(account.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Team", value: account.team)
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            model.signOut()
                        }
                    } else {
                        Button("Sign in with Apple ID", systemImage: "person.badge.key") { showSignIn = true }
                    }
                } header: {
                    Text("Apple ID")
                } footer: {
                    Text("Used to get free 7-day signing profiles for your watch apps. A free Apple ID works — a secondary one is safest. Your password goes only to Apple; WatchLoader keeps just a session token on this iPhone.")
                }

                Section {
                    LabeledContent("Watch UDID") {
                        Text(model.watchUDID.isEmpty ? "Run Test watch" : model.watchUDID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    LabeledContent("iPhone address") {
                        TextField("10.7.0.1", text: $model.phoneIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($editingAddress)
                            .onSubmit { editingAddress = false }
                            .font(.body.monospaced())
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("LocalDevVPN's peer address — normally 10.7.0.1. Keep Personal Hotspot off and stay on Wi-Fi.")
                }

                Section {
                    PairingRow(title: "iPhone", file: "phone.plist", ok: model.hasPhonePairing) {
                        pendingKind = .phonePairing
                        showImporter = true
                    }
                    PairingRow(title: "Apple Watch", file: "watch.plist", ok: model.hasWatchPairing) {
                        pendingKind = .watchPairing
                        showImporter = true
                    }
                } header: {
                    Text("Pairing files")
                } footer: {
                    Text("Pairing records are private keys. They stay in WatchLoader's Documents folder on this iPhone.")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Apps in library", value: "\(model.apps.count)")
                    Link(destination: URL(string: "https://github.com/BasimNasserMu/watchloader")!) {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }

                Section {
                    Button("Clear log", systemImage: "trash", role: .destructive) { model.log.removeAll() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("10.7.0.1") { model.phoneIP = "10.7.0.1" }
                    Spacer()
                    Button("Done") { editingAddress = false }
                        .fontWeight(.semibold)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.propertyList, .xml, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result { model.importFiles(urls, kind: pendingKind) }
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var failed = false
    @FocusState private var field: Field?

    enum Field { case email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($field, equals: .email)
                        .onSubmit { field = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($field, equals: .password)
                        .onSubmit(signIn)
                } footer: {
                    if failed {
                        Text("Sign-in failed — check the log on the Devices tab.").foregroundStyle(.red)
                    } else {
                        Text("You'll be asked for a two-factor code next.")
                    }
                }
                if model.busy {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(model.status).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in", action: signIn)
                        .disabled(model.busy || email.isEmpty || password.isEmpty)
                }
            }
            .onAppear { field = .email }
        }
        .interactiveDismissDisabled(model.busy)
    }

    private func signIn() {
        guard !email.isEmpty, !password.isEmpty, !model.busy else { return }
        failed = false
        field = nil
        model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password) { ok in
            if ok {
                password = ""
                dismiss()
            } else {
                failed = true
            }
        }
    }
}

private struct PairingRow: View {
    let title: String
    let file: String
    let ok: Bool
    let onImport: () -> Void

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(ok ? file : "Not imported").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(ok ? "Replace" : "Import", action: onImport)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}
