import AppKit
import MaludexControlCenterCore
import SwiftUI

struct ControlCenterView: View {
    @AppStorage("repoRoot") private var repoRoot = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Documents/maludex"
    @State private var report: DoctorReport?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var qrImage: NSImage?

    private var runner: DoctorRunner {
        DoctorRunner(repoRoot: URL(fileURLWithPath: repoRoot))
    }

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.96, blue: 0.92).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 18) {
                        repoPicker
                        overviewGrid
                        actionPanel
                        issuesPanel
                        qrPanel
                    }
                    .padding(24)
                }
            }
        }
        .task {
            await refresh()
        }
        .alert("maludex Control Center", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(red: 0.03, green: 0.19, blue: 0.24), Color(red: 0.73, green: 0.30, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "terminal")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("maludex")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Control Center")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.regularMaterial)
    }

    private var statusBadge: some View {
        let status = report?.status ?? .warning
        return Label(report?.statusLabel ?? "Checking", systemImage: statusIcon(status))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(statusColor(status).opacity(0.12)))
    }

    private var repoPicker: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(Color(red: 0.02, green: 0.45, blue: 0.40))
            TextField("Repository path", text: $repoRoot)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
            Button {
                chooseRepo()
            } label: {
                Label("Choose", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background { panelBackground }
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            MetricCard(title: "Bridge", value: report?.bridge?.reachable == true ? "Reachable" : "Offline", symbol: "network", tint: statusColor(report?.status ?? .warning))
            MetricCard(title: "Endpoint", value: report?.endpoint ?? "Checking", symbol: "point.3.connected.trianglepath.dotted", tint: Color(red: 0.02, green: 0.45, blue: 0.40))
            MetricCard(title: "Version", value: versionText, symbol: "tag", tint: Color(red: 0.72, green: 0.41, blue: 0.18))
        }
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bridge Actions")
                .font(.system(size: 18, weight: .bold))
            HStack(spacing: 12) {
                ActionButton(title: "Repair", icon: "wrench.and.screwdriver", tint: Color(red: 0.02, green: 0.45, blue: 0.40), disabled: isBusy) {
                    Task { await perform(.repair) }
                }
                ActionButton(title: "Restart", icon: "arrow.triangle.2.circlepath", tint: Color(red: 0.02, green: 0.45, blue: 0.40), disabled: isBusy) {
                    Task { await perform(.restart) }
                }
                ActionButton(title: "Start", icon: "play.fill", tint: Color(red: 0.18, green: 0.49, blue: 0.24), disabled: isBusy) {
                    Task { await perform(.start) }
                }
                ActionButton(title: "Stop", icon: "stop.fill", tint: Color(red: 0.69, green: 0.22, blue: 0.18), disabled: isBusy) {
                    Task { await perform(.stop) }
                }
                ActionButton(title: "Pair", icon: "qrcode", tint: Color(red: 0.08, green: 0.34, blue: 0.52), disabled: isBusy) {
                    Task { await pairingQR() }
                }
                ActionButton(title: "Rotate", icon: "key.fill", tint: Color(red: 0.72, green: 0.41, blue: 0.18), disabled: isBusy) {
                    Task { await rotateToken() }
                }
            }
        }
        .padding(18)
        .background { panelBackground }
    }

    private var issuesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostics")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    copyReport()
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(report == nil)
            }

            if let report, report.issues.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.24))
                    Text(report.summary)
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(report?.issues ?? []) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: issue.severity == "error" ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(issue.severity == "error" ? Color(red: 0.69, green: 0.22, blue: 0.18) : Color(red: 0.72, green: 0.41, blue: 0.18))
                            Text(issue.title)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            if issue.repairable {
                                Text("Repairable")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(red: 0.02, green: 0.45, blue: 0.40))
                            }
                        }
                        Text(issue.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(18)
        .background { panelBackground }
    }

    @ViewBuilder
    private var qrPanel: some View {
        if let qrImage {
            HStack(spacing: 18) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 176, height: 176)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pairing QR")
                        .font(.system(size: 18, weight: .bold))
                    Text("Treat this QR like a password.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.69, green: 0.22, blue: 0.18))
                    Text(report?.endpoint ?? "")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background { panelBackground }
        }
    }

    private var versionText: String {
        guard let report else { return "Checking" }
        if let bridgeVersion = report.bridge?.bridgeVersion {
            return "\(bridgeVersion) / \(report.packageVersion)"
        }
        return report.packageVersion
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.72))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
    }

    private func refresh() async {
        await runBusy {
            report = try await runner.run()
        }
    }

    private func perform(_ action: ControlCenterAction) async {
        await runBusy {
            report = try await runner.run(action)
        }
    }

    private func pairingQR() async {
        let url = URL(fileURLWithPath: "/tmp/maludex-pairing.png")
        await runBusy {
            report = try await runner.run(.pairingQR(url))
            qrImage = NSImage(contentsOf: url)
        }
    }

    private func rotateToken() async {
        let url = URL(fileURLWithPath: "/tmp/maludex-pairing.png")
        await runBusy {
            report = try await runner.run(.rotateToken(url))
            qrImage = NSImage(contentsOf: url)
        }
    }

    private func runBusy(_ operation: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: repoRoot)
        if panel.runModal() == .OK, let url = panel.url {
            repoRoot = url.path
            Task { await refresh() }
        }
    }

    private func copyReport() {
        guard let report else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func statusIcon(_ status: DoctorStatus) -> String {
        switch status {
        case .healthy:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.circle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    private func statusColor(_ status: DoctorStatus) -> Color {
        switch status {
        case .healthy:
            Color(red: 0.18, green: 0.49, blue: 0.24)
        case .warning:
            Color(red: 0.72, green: 0.41, blue: 0.18)
        case .error:
            Color(red: 0.69, green: 0.22, blue: 0.18)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 6)
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            .frame(width: 104, height: 76)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(tint.opacity(disabled ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 12))
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }
}
