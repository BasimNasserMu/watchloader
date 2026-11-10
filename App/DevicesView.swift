import SwiftUI
import UIKit

struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    WatchHero()

                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button { model.probeWatch() } label: {
                                Label("Test watch", systemImage: "applewatch.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)

                            Button { model.diagnose() } label: {
                                Label("Diagnose", systemImage: "stethoscope")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        .controlSize(.large)
                        .disabled(model.busy)
                    }

                    if model.busy { ActivityCard() }
                    ChecklistCard()
                    LogCard()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(.snappy, value: model.busy)
            }
            .background(AppBackground())
            .navigationTitle("Devices")
            .refreshable { model.refresh() }
        }
    }
}

private struct WatchHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (title, subtitle, color, icon): (String, String, Color, String) = {
            switch model.probe {
            case .unknown:
                return ("Not tested", "Tap Test watch to connect through your iPhone.", .secondary, "applewatch")
            case .ok(let info):
                return ("Connected", info, .green, "applewatch.radiowaves.left.and.right")
            case .failed(let err):
                return ("Unreachable", err, .red, "applewatch.slash")
            }
        }()
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: model.busy)
                .contentTransition(.symbolEffect(.replace))
                .padding(.top, 6)
            Text(title).font(.title2.bold())
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 30)
    }
}

private struct ChecklistCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Checklist").font(.headline)
            CheckRow(title: "iPhone pairing", detail: model.hasPhonePairing ? "phone.plist" : "Import in Settings",
                     ok: model.hasPhonePairing, icon: "iphone")
            CheckRow(title: "Watch pairing", detail: model.hasWatchPairing ? "watch.plist" : "Import in Settings",
                     ok: model.hasWatchPairing, icon: "applewatch")
            CheckRow(title: "LocalDevVPN", detail: model.vpnUp ? "Tunnel is up" : "Open LocalDevVPN and connect",
                     ok: model.vpnUp, icon: "lock.shield")
            CheckRow(title: "Wi-Fi", detail: model.wifiUp ? "Connected as a client" : "Join a Wi-Fi network",
                     ok: model.wifiUp, icon: "wifi")
            CheckRow(title: "Personal Hotspot",
                     detail: model.hotspotOn ? "Turn it off — it blocks the connection" : "Off",
                     ok: !model.hotspotOn, icon: "personalhotspot")
        }
        .glassCard()
    }
}

private struct LogCard: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                if !model.log.isEmpty {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = model.log.map(\.text).joined(separator: "\n")
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    Button("Clear", systemImage: "trash") { model.log.removeAll() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .labelStyle(.iconOnly)
                }
            }
            if model.log.isEmpty {
                Text("Nothing yet").font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.log.suffix(200)) { line in
                        Text(line.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .glassCard()
    }

    private func color(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .ok: return .green
        case .fail: return .red
        case .warn: return .orange
        case .step: return .secondary
        case .info: return .primary
        }
    }
}
