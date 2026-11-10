import Darwin
import SwiftUI
import UIKit

@main
struct WatchLoaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Model

struct LogLine: Identifiable {
    enum Kind { case info, step, ok, fail, warn }
    let id = UUID()
    let text: String
    let kind: Kind

    init(_ text: String) {
        self.text = text
        if text.hasPrefix("✅") || text.contains(" OK") { kind = .ok }
        else if text.hasPrefix("❌") || text.contains("FAIL") { kind = .fail }
        else if text.hasPrefix("⚠️") { kind = .warn }
        else if text.hasPrefix("  ") || text.hasPrefix("==") { kind = .step }
        else { kind = .info }
    }
}

/// Files live in the app's Documents folder (visible in the Files app and over USB):
///   phone.plist  – iPhone pairing record (host <-> this iPhone)
///   watch.plist  – Apple Watch pairing record (host <-> watch, created by watchlink.py)
///   *.ipa        – watch-only apps (Payload/<Name>.app) to install
final class Loader: ObservableObject {
    @Published var phoneIP = UserDefaults.standard.string(forKey: "phoneIP") ?? "10.7.0.1" {
        didSet { UserDefaults.standard.set(phoneIP, forKey: "phoneIP") }
    }
    @Published var log: [LogLine] = []
    @Published var ipas: [URL] = []
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var hasPhonePairing = false
    @Published var hasWatchPairing = false
    @Published var vpnInterfaces: [String] = []

    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var phonePairing: URL { docs.appendingPathComponent("phone.plist") }
    var watchPairing: URL { docs.appendingPathComponent("watch.plist") }
    var ready: Bool { hasPhonePairing && hasWatchPairing }

    func refresh() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        ipas = items.filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        hasPhonePairing = fm.fileExists(atPath: phonePairing.path)
        hasWatchPairing = fm.fileExists(atPath: watchPairing.path)
        vpnInterfaces = Loader.interfaces().filter { $0.hasPrefix("utun") }
    }

    func add(_ s: String) { log.append(LogLine(s)) }

    func delete(_ ipa: URL) {
        try? FileManager.default.removeItem(at: ipa)
        refresh()
    }

    func size(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// IPv4 addresses of every interface (en0 = Wi-Fi, utunN = VPN tunnels, bridge = hotspot).
    static func interfaces() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append("\(String(cString: p.pointee.ifa_name)) \(String(cString: host))")
            }
        }
        return out
    }

    // MARK: Actions

    func diagnose() {
        guard !busy else { return }
        refresh()
        guard hasPhonePairing else { add("⚠️ phone.plist is missing from Documents"); return }
        busy = true
        status = "Diagnosing…"
        add("Interfaces: " + Loader.interfaces().joined(separator: ", "))
        let candidates = [phoneIP, "10.7.0.1", "10.7.0.2"].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let addrs = candidates.joined(separator: ","), phone = phonePairing.path
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [CChar](repeating: 0, count: 8192)
            _ = wl_diagnose(addrs, phone, &buf, buf.count)
            let report = String(cString: buf)
            DispatchQueue.main.async {
                report.split(separator: "\n").forEach { self.add(String($0)) }
                self.busy = false
                self.status = ""
            }
        }
    }

    func probe() {
        start("Testing connection to watch…") { ip, phone, watch in
            var buf = [CChar](repeating: 0, count: 2048)
            let rc = wl_probe(ip, phone, watch, &buf, buf.count)
            return (rc, String(cString: buf))
        }
    }

    func install(_ ipa: URL) {
        start("Installing \(ipa.deletingPathExtension().lastPathComponent)…") { [unowned self] ip, phone, watch in
            var buf = [CChar](repeating: 0, count: 2048)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let cb: wl_progress_cb = { ctx, status, pct in
                guard let ctx, let status else { return }
                let me = Unmanaged<Loader>.fromOpaque(ctx).takeUnretainedValue()
                let text = String(cString: status)
                DispatchQueue.main.async {
                    me.progress = Double(pct) / 100
                    me.status = text
                    me.add("  \(text) \(pct)%")
                }
            }
            let rc = ipa.path.withCString { wl_install(ip, phone, watch, $0, cb, ctx, &buf, buf.count) }
            return (rc, String(cString: buf))
        }
    }

    private func start(_ title: String, _ work: @escaping (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> (Int32, String)) {
        guard !busy else { return }
        refresh()
        guard ready else { add("⚠️ phone.plist / watch.plist missing from Documents"); return }
        busy = true
        progress = 0
        status = title
        add(title)
        let ip = phoneIP, phone = phonePairing.path, watch = watchPairing.path
        DispatchQueue.global(qos: .userInitiated).async {
            let (rc, msg) = ip.withCString { i in phone.withCString { p in watch.withCString { w in work(i, p, w) } } }
            DispatchQueue.main.async {
                self.add(rc == 0 ? "✅ \(msg)" : "❌ \(msg)")
                self.busy = false
                self.status = ""
                if rc == 0 { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                else { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            }
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var loader = Loader()
    @Environment(\.scenePhase) private var phase
    @FocusState private var editingIP: Bool
    @State private var pendingDelete: URL?
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                connectionSection
                appsSection
                if loader.busy { progressSection }
                logSection
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("WatchLoader")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { loader.refresh() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("10.7.0.1") { loader.phoneIP = "10.7.0.1" }
                    Button("10.7.0.2") { loader.phoneIP = "10.7.0.2" }
                    Spacer()
                    Button("Done") { editingIP = false }.bold()
                }
            }
            .refreshable { loader.refresh() }
            .confirmationDialog(
                "Delete \(pendingDelete?.lastPathComponent ?? "")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let u = pendingDelete { loader.delete(u) }
                    pendingDelete = nil
                }
            }
        }
        .onAppear { loader.refresh() }
        .onChange(of: phase) { _, p in if p == .active { loader.refresh() } }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: loader.ready ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(loader.ready ? Color.accentColor : .secondary)
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loader.ready ? "Ready" : "Setup needed").font(.headline)
                    Text(loader.ready ? "Pairing records found" : "Add phone.plist and watch.plist to Documents")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            StatusRow("iPhone pairing", detail: "phone.plist", ok: loader.hasPhonePairing)
            StatusRow("Watch pairing", detail: "watch.plist", ok: loader.hasWatchPairing)
            StatusRow(
                "VPN tunnel",
                detail: loader.vpnInterfaces.isEmpty ? "Connect LocalDevVPN" : loader.vpnInterfaces.joined(separator: ", "),
                ok: !loader.vpnInterfaces.isEmpty
            )
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("iPhone address") {
                TextField("10.7.0.1", text: $loader.phoneIP)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingIP)
                    .onSubmit { editingIP = false }
                    .font(.body.monospaced())
            }
            HStack(spacing: 10) {
                ActionButton("Test watch", icon: "applewatch", prominent: true) {
                    editingIP = false
                    loader.probe()
                }
                ActionButton("Diagnose", icon: "stethoscope", prominent: false) {
                    editingIP = false
                    loader.diagnose()
                }
            }
            .disabled(loader.busy)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        } header: {
            Text("Connection")
        } footer: {
            Text("LocalDevVPN must be connected and the iPhone joined to a Wi-Fi network.")
        }
    }

    private var appsSection: some View {
        Section {
            if loader.ipas.isEmpty {
                ContentUnavailableView(
                    "No watch apps",
                    systemImage: "square.and.arrow.down.on.square",
                    description: Text("Add watch-only .ipa files to WatchLoader in the Files app.")
                )
            }
            ForEach(loader.ipas, id: \.self) { ipa in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 42, height: 42)
                        .overlay(Image(systemName: "applewatch").foregroundStyle(.white).font(.title3))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ipa.deletingPathExtension().lastPathComponent).font(.body.weight(.semibold))
                        Text(loader.size(of: ipa)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") { loader.install(ipa) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(loader.busy || !loader.ready)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = ipa }
                }
            }
        } header: {
            Text("Watch apps")
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(loader.status).font(.subheadline.weight(.medium))
                if loader.progress > 0 {
                    ProgressView(value: loader.progress)
                } else {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var logSection: some View {
        Section {
            if loader.log.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
            ForEach(loader.log) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color(for: line.kind))
                    .textSelection(.enabled)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                if !loader.log.isEmpty {
                    Button(showCopied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = loader.log.map(\.text).joined(separator: "\n")
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
                    }
                    Button("Clear") { loader.log.removeAll() }
                }
            }
            .font(.footnote)
            .textCase(nil)
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .ok: return .green
        case .fail: return .red
        case .warn: return .orange
        case .step: return .secondary
        case .info: return .primary
        }
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let ok: Bool
    init(_ title: String, detail: String, ok: Bool) { self.title = title; self.detail = detail; self.ok = ok }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.title3)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let prominent: Bool
    let action: () -> Void
    init(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.prominent = prominent; self.action = action
    }

    var body: some View {
        Group {
            if prominent {
                Button(action: action) { label }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private var label: some View {
        Label(title, systemImage: icon).frame(maxWidth: .infinity)
    }
}
