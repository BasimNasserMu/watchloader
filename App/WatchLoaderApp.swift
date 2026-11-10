import SwiftUI

@main
struct WatchLoaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Files live in the app's Documents folder (visible in the Files app and over USB):
///   phone.plist  – iPhone pairing record (host <-> this iPhone)
///   watch.plist  – Apple Watch pairing record (host <-> watch, created by watchlink.py)
///   *.ipa        – watch-only apps (Payload/<Name>.app) to install
final class Loader: ObservableObject {
    @Published var phoneIP = "10.7.0.1"
    @Published var log: [String] = []
    @Published var ipas: [URL] = []
    @Published var busy = false
    @Published var progress: Double = 0

    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var phonePairing: URL { docs.appendingPathComponent("phone.plist") }
    var watchPairing: URL { docs.appendingPathComponent("watch.plist") }
    var hasPhonePairing: Bool { FileManager.default.fileExists(atPath: phonePairing.path) }
    var hasWatchPairing: Bool { FileManager.default.fileExists(atPath: watchPairing.path) }

    func refresh() {
        let items = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        ipas = items.filter { $0.pathExtension.lowercased() == "ipa" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        objectWillChange.send()
    }

    func say(_ s: String) {
        DispatchQueue.main.async { self.log.append(s) }
    }

    func probe() {
        start("Testing connection…") { ip, phone, watch in
            var buf = [CChar](repeating: 0, count: 2048)
            let rc = wl_probe(ip, phone, watch, &buf, buf.count)
            return (rc, String(cString: buf))
        }
    }

    func install(_ ipa: URL) {
        start("Installing \(ipa.lastPathComponent)…") { [unowned self] ip, phone, watch in
            var buf = [CChar](repeating: 0, count: 2048)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let cb: wl_progress_cb = { ctx, status, pct in
                guard let ctx, let status else { return }
                let me = Unmanaged<Loader>.fromOpaque(ctx).takeUnretainedValue()
                let text = String(cString: status)
                DispatchQueue.main.async {
                    me.progress = Double(pct) / 100
                    me.log.append("  \(text) \(pct)%")
                }
            }
            let rc = ipa.path.withCString { wl_install(ip, phone, watch, $0, cb, ctx, &buf, buf.count) }
            return (rc, String(cString: buf))
        }
    }

    private func start(_ title: String, _ work: @escaping (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> (Int32, String)) {
        guard !busy else { return }
        guard hasPhonePairing, hasWatchPairing else {
            log.append("⚠️ Missing phone.plist / watch.plist in Documents")
            return
        }
        busy = true
        progress = 0
        log.append(title)
        let ip = phoneIP, phone = phonePairing.path, watch = watchPairing.path
        DispatchQueue.global(qos: .userInitiated).async {
            let (rc, msg) = ip.withCString { i in phone.withCString { p in watch.withCString { w in work(i, p, w) } } }
            DispatchQueue.main.async {
                self.log.append(rc == 0 ? "✅ \(msg)" : "❌ \(msg)")
                self.busy = false
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var loader = Loader()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                Section("Setup") {
                    StatusRow("iPhone pairing (phone.plist)", loader.hasPhonePairing)
                    StatusRow("Watch pairing (watch.plist)", loader.hasWatchPairing)
                    HStack {
                        Text("iPhone address")
                        Spacer()
                        TextField("10.7.0.1", text: $loader.phoneIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .font(.body.monospaced())
                    }
                    Button("Test connection to watch", systemImage: "applewatch.radiowaves.left.and.right") {
                        loader.probe()
                    }
                    .disabled(loader.busy)
                }

                Section("Watch apps in Documents") {
                    if loader.ipas.isEmpty {
                        Text("Put watch-only .ipa files in WatchLoader's Documents folder.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(loader.ipas, id: \.self) { ipa in
                        Button {
                            loader.install(ipa)
                        } label: {
                            Label(ipa.deletingPathExtension().lastPathComponent, systemImage: "arrow.down.app")
                        }
                        .disabled(loader.busy)
                    }
                }

                if loader.busy {
                    Section { ProgressView(value: loader.progress) }
                }

                Section("Log") {
                    ForEach(Array(loader.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("WatchLoader")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { loader.refresh() }
            }
            .refreshable { loader.refresh() }
        }
        .onAppear { loader.refresh() }
        .onChange(of: phase) { _, p in if p == .active { loader.refresh() } }
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool
    init(_ title: String, _ ok: Bool) { self.title = title; self.ok = ok }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
        }
    }
}
