import SwiftUI

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var pendingDelete: WatchApp?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if model.setupIssues > 0 { SetupHint() }
                    if model.busy { ActivityCard() }
                    ForEach(model.apps) { app in
                        AppCard(app: app) { pendingDelete = app }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(.snappy, value: model.busy)
                .animation(.snappy, value: model.apps)
            }
            .overlay {
                if model.apps.isEmpty {
                    ContentUnavailableView {
                        Label("No watch apps", systemImage: "applewatch.slash")
                    } description: {
                        Text("Import a watch-only .ipa to install it on your Apple Watch.")
                    } actions: {
                        Button("Import IPA", systemImage: "plus") { importing = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .background(AppBackground())
            .navigationTitle("Watch Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import", systemImage: "plus") { importing = true }
                }
            }
            .refreshable { model.refresh() }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.ipa, .zip, .data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { model.importFiles(urls, kind: .apps) }
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.name ?? "app")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let app = pendingDelete { model.delete(app) }
                    pendingDelete = nil
                }
            } message: {
                Text("Removes the .ipa from WatchLoader. The app on your watch is not affected.")
            }
        }
    }
}

struct AppCard: View {
    @Environment(AppModel.self) private var model
    let app: WatchApp
    var onDelete: () -> Void

    private var isInstalling: Bool { model.busy && model.installing == app.url }

    var body: some View {
        HStack(spacing: 14) {
            AppIcon(name: app.name)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.headline).lineLimit(1)
                Text([app.version.isEmpty ? nil : "v\(app.version)", app.sizeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ExpiryBadge(app: app)
            }
            Spacer(minLength: 8)
            if isInstalling {
                ProgressRing(value: model.progress)
            } else if model.account != nil && (app.isExpired || (app.daysLeft ?? 0) <= 2) {
                Button("Re-sign", systemImage: "arrow.triangle.2.circlepath") { model.resignAndInstall(app) }
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
                    .disabled(model.busy || !model.ready)
            } else {
                Button("Install") { model.install(app) }
                    .buttonStyle(.glassProminent)
                    .disabled(model.busy || !model.ready || app.isExpired)
            }
        }
        .glassCard()
        .contextMenu {
            Button("Install on watch", systemImage: "arrow.down.circle") { model.install(app) }
                .disabled(model.busy || !model.ready || app.isExpired)
            Button("Re-sign & install", systemImage: "arrow.triangle.2.circlepath") { model.resignAndInstall(app) }
                .disabled(model.busy || !model.ready || model.account == nil)
            Section {
                if !app.bundleID.isEmpty { Text(app.bundleID) }
                if let team = app.teamName { Text("Signed by \(team)") }
                if app.deviceCount > 0 { Text("Profile covers \(app.deviceCount) device\(app.deviceCount == 1 ? "" : "s")") }
                if !app.isWatchApp { Text("⚠️ Doesn't look like a watch app") }
            }
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}
