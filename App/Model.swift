import Darwin
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Value types

struct LogLine: Identifiable, Hashable {
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

struct WatchApp: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String
    var bundleID = ""
    var version = ""
    var expires: Date?
    var teamName: String?
    var deviceCount = 0
    var isWatchApp = false
    var size: Int64 = 0

    var daysLeft: Int? {
        guard let expires else { return nil }
        return Int((expires.timeIntervalSinceNow / 86_400).rounded(.up))
    }
    var isExpired: Bool { (expires ?? .distantFuture) < .now }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

enum ProbeState: Equatable {
    case unknown
    case ok(String)
    case failed(String)
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
}

// MARK: - App model

/// Files live in the app's Documents folder (visible in the Files app and over USB):
///   phone.plist  – iPhone pairing record
///   watch.plist  – Apple Watch pairing record
///   *.ipa        – watch-only apps (Payload/<Name>.app) to install
@Observable
final class AppModel {
    enum ImportKind { case apps, phonePairing, watchPairing }

    var phoneIP: String = UserDefaults.standard.string(forKey: "phoneIP") ?? "10.7.0.1" {
        didSet { UserDefaults.standard.set(phoneIP, forKey: "phoneIP") }
    }
    var apps: [WatchApp] = []
    var log: [LogLine] = []
    var busy = false
    var status = ""
    var progress: Double = 0
    var installing: URL?
    var probe: ProbeState = .unknown
    var hasPhonePairing = false
    var hasWatchPairing = false
    var interfaces: [String] = []
    var successTick = 0
    var failureTick = 0

    @ObservationIgnored let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var phonePairing: URL { docs.appendingPathComponent("phone.plist") }
    var watchPairing: URL { docs.appendingPathComponent("watch.plist") }

    var ready: Bool { hasPhonePairing && hasWatchPairing }
    var vpnUp: Bool { interfaces.contains { $0.hasPrefix("utun") && $0.contains(" 10.7.") } }
    var wifiUp: Bool { interfaces.contains { $0.hasPrefix("en0 ") } }
    var hotspotOn: Bool { interfaces.contains { $0.hasPrefix("bridge") } }
    var setupIssues: Int { [hasPhonePairing, hasWatchPairing, vpnUp, wifiUp, !hotspotOn].filter { !$0 }.count }

    // MARK: Files

    func refresh() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        apps = items
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(AppModel.readInfo)
        hasPhonePairing = fm.fileExists(atPath: phonePairing.path)
        hasWatchPairing = fm.fileExists(atPath: watchPairing.path)
        interfaces = AppModel.interfaces()
    }

    static func readInfo(_ url: URL) -> WatchApp {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var app = WatchApp(url: url, name: url.deletingPathExtension().lastPathComponent, size: size)
        var buf = [CChar](repeating: 0, count: 16_384)
        let rc = url.path.withCString { wl_ipa_info($0, &buf, buf.count) }
        guard rc == 0,
              let data = String(cString: buf).data(using: .utf8),
              let d = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return app }
        app.name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String) ?? app.name
        app.bundleID = d["CFBundleIdentifier"] as? String ?? ""
        app.version = d["CFBundleShortVersionString"] as? String ?? ""
        app.expires = d["ExpirationDate"] as? Date
        app.teamName = d["TeamName"] as? String
        app.deviceCount = d["DeviceCount"] as? Int ?? 0
        app.isWatchApp = d["IsWatchApp"] as? Bool ?? false
        return app
    }

    func importFiles(_ urls: [URL], kind: ImportKind) {
        let fm = FileManager.default
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest: URL
            switch kind {
            case .apps: dest = docs.appendingPathComponent(url.lastPathComponent)
            case .phonePairing: dest = phonePairing
            case .watchPairing: dest = watchPairing
            }
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: url, to: dest)
                add("Imported \(url.lastPathComponent) → \(dest.lastPathComponent)")
            } catch {
                add("❌ Import failed: \(error.localizedDescription)")
            }
        }
        refresh()
    }

    func delete(_ app: WatchApp) {
        try? FileManager.default.removeItem(at: app.url)
        refresh()
    }

    func add(_ s: String) {
        log.append(LogLine(s))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    /// IPv4 address of every interface: en0 = Wi-Fi, utunN = VPN tunnels, bridgeN = Personal Hotspot.
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
        guard hasPhonePairing else { add("⚠️ phone.plist is missing"); return }
        busy = true
        progress = 0
        status = "Diagnosing iPhone link…"
        add("Interfaces: " + interfaces.joined(separator: ", "))
        let candidates = [phoneIP, "10.7.0.1"].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
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

    func probeWatch() {
        run("Connecting to your watch…") { ip, phone, watch in
            var buf = [CChar](repeating: 0, count: 2048)
            let rc = wl_probe(ip, phone, watch, &buf, buf.count)
            return (rc, String(cString: buf))
        } done: { ok, msg in
            self.probe = ok ? .ok(msg) : .failed(msg)
        }
    }

    func install(_ app: WatchApp) {
        installing = app.url
        run("Installing \(app.name)…") { [unowned self] ip, phone, watch in
            var buf = [CChar](repeating: 0, count: 2048)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let cb: wl_progress_cb = { ctx, status, pct in
                guard let ctx, let status else { return }
                let me = Unmanaged<AppModel>.fromOpaque(ctx).takeUnretainedValue()
                let text = String(cString: status)
                DispatchQueue.main.async {
                    me.progress = Double(pct) / 100
                    me.status = text
                    me.add("  \(text) \(pct)%")
                }
            }
            let rc = app.url.path.withCString { wl_install(ip, phone, watch, $0, cb, ctx, &buf, buf.count) }
            return (rc, String(cString: buf))
        } done: { _, _ in
            self.installing = nil
        }
    }

    private func run(
        _ title: String,
        _ work: @escaping (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> (Int32, String),
        done: @escaping (Bool, String) -> Void
    ) {
        guard !busy else { return }
        refresh()
        guard ready else {
            add("⚠️ Pairing files missing — import them in Settings")
            done(false, "Pairing files missing")
            return
        }
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
                if rc == 0 { self.successTick += 1 } else { self.failureTick += 1 }
                done(rc == 0, msg)
            }
        }
    }
}
