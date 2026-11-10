import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var editingAddress: Bool
    @State private var showImporter = false
    @State private var pendingKind: AppModel.ImportKind = .phonePairing

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
