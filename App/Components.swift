import SwiftUI

// MARK: - Liquid Glass helpers

extension View {
    /// A padded, full-width Liquid Glass card.
    func glassCard(cornerRadius: CGFloat = 24, tint: Color? = nil) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
    }
}

/// Soft colourful backdrop so the glass has something to refract.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(
                colors: [Color.indigo.opacity(0.30), Color.teal.opacity(0.18), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.purple.opacity(0.18))
                .frame(width: 320)
                .blur(radius: 80)
                .offset(x: 140, y: -260)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Small views

struct AppIcon: View {
    let name: String
    var size: CGFloat = 56

    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.98),
                        Color(hue: hue, saturation: 0.85, brightness: 0.72),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "applewatch")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}

struct ExpiryBadge: View {
    let app: WatchApp

    var body: some View {
        let (text, color): (String, Color) = {
            guard let d = app.daysLeft else { return ("No profile", .gray) }
            if d <= 0 { return ("Expired", .red) }
            if d <= 2 { return (d == 1 ? "1 day left" : "\(d) days left", .orange) }
            return ("\(d) days left", .green)
        }()
        Label(text, systemImage: app.isExpired ? "exclamationmark.triangle.fill" : "clock")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.03, value))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .frame(width: 42, height: 42)
        .animation(.easeInOut(duration: 0.25), value: value)
    }
}

struct CheckRow: View {
    let title: String
    let detail: String
    let ok: Bool
    var icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(ok ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(ok ? .green : .red)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

struct ActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text(model.status).font(.subheadline.weight(.medium)).lineLimit(2)
            }
            if model.progress > 0 {
                ProgressView(value: model.progress)
            }
        }
        .glassCard(tint: .accentColor)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct SetupHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Setup needed").font(.headline)
                Text("\(model.setupIssues) item\(model.setupIssues == 1 ? "" : "s") to fix — see the Devices tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard(tint: .orange)
    }
}
