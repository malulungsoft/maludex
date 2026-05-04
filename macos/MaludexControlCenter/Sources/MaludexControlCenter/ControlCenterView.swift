import AppKit
import MaludexControlCenterCore
import SwiftUI

struct ControlCenterView: View {
    @AppStorage("repoRoot") private var repoRoot = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Documents/maludex"
    @AppStorage("languageCode") private var languageCode = ControlCenterLanguage.fallback.rawValue
    @State private var report: DoctorReport?
    @State private var handoffReport: MobileHandoffReport?
    @State private var isBusy = false
    @State private var isHandoffBusy = false
    @State private var errorMessage: String?
    @State private var handoffError: String?
    @State private var qrImage: NSImage?
    @State private var qrImageURL: URL?

    private var runner: DoctorRunner {
        DoctorRunner(repoRoot: URL(fileURLWithPath: repoRoot))
    }

    private var copy: ControlCenterCopy {
        ControlCenterCopy(languageCode: languageCode)
    }

    private var actionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)]
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
                        nextStepPanel
                        actionPanel
                        handoffPanel
                        issuesPanel
                        qrPanel
                    }
                    .padding(24)
                }
            }
        }
        .task {
            await refresh()
            await refreshHandoff()
        }
        .alert("maludex \(copy.appSubtitle)", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(copy.okButton, role: .cancel) { errorMessage = nil }
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
                Text(copy.appSubtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker(copy.languageLabel, selection: $languageCode) {
                ForEach(ControlCenterLanguage.allCases) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            statusBadge
            Button {
                Task {
                    await refresh()
                    await refreshHandoff()
                }
            } label: {
                Label(copy.refreshButton, systemImage: "arrow.clockwise")
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
        return Label(report.map { copy.statusLabel($0.status) } ?? copy.checkingValue, systemImage: statusIcon(status))
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
            TextField(copy.repositoryPathPlaceholder, text: $repoRoot)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
            Button {
                chooseRepo()
            } label: {
                Label(copy.chooseButton, systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background { panelBackground }
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            MetricCard(title: copy.bridgeTitle, value: report?.bridge?.reachable == true ? copy.reachableValue : copy.offlineValue, symbol: "network", tint: statusColor(report?.status ?? .warning))
            MetricCard(title: copy.endpointTitle, value: report?.endpoint ?? copy.checkingValue, symbol: "point.3.connected.trianglepath.dotted", tint: Color(red: 0.02, green: 0.45, blue: 0.40))
            MetricCard(title: copy.versionTitle, value: versionText, symbol: "tag", tint: Color(red: 0.72, green: 0.41, blue: 0.18))
        }
    }

    private var nextStepPanel: some View {
        HStack(spacing: 14) {
            Image(systemName: report?.status == .healthy ? "checkmark.seal.fill" : "arrow.forward.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(statusColor(report?.status ?? .warning))
                .frame(width: 44, height: 44)
                .background(statusColor(report?.status ?? .warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(copy.nextStepTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(nextStepTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                if let summary = report?.summary {
                    Text(summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if let action = report?.primaryAction, action != "none" {
                Button {
                    Task { await performPrimaryAction(action) }
                } label: {
                    Label(copy.recommendedActionTitle(action), systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(18)
        .background { panelBackground }
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.bridgeActionsTitle)
                .font(.system(size: 18, weight: .bold))
            LazyVGrid(columns: actionColumns, spacing: 12) {
                ActionButton(title: copy.repairButton, icon: "wrench.and.screwdriver", tint: Color(red: 0.02, green: 0.45, blue: 0.40), disabled: isBusy) {
                    Task { await perform(.repair) }
                }
                ActionButton(title: copy.restartButton, icon: "arrow.triangle.2.circlepath", tint: Color(red: 0.02, green: 0.45, blue: 0.40), disabled: isBusy) {
                    Task { await perform(.restart) }
                }
                ActionButton(title: copy.startButton, icon: "play.fill", tint: Color(red: 0.18, green: 0.49, blue: 0.24), disabled: isBusy) {
                    Task { await perform(.start) }
                }
                ActionButton(title: copy.stopButton, icon: "stop.fill", tint: Color(red: 0.69, green: 0.22, blue: 0.18), disabled: isBusy) {
                    Task { await perform(.stop) }
                }
                ActionButton(title: copy.pairButton, icon: "qrcode", tint: Color(red: 0.08, green: 0.34, blue: 0.52), disabled: isBusy) {
                    Task { await pairingQR() }
                }
                ActionButton(title: copy.rotateButton, icon: "key.fill", tint: Color(red: 0.72, green: 0.41, blue: 0.18), disabled: isBusy) {
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
                Text(copy.diagnosticsTitle)
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    copyReport()
                } label: {
                    Label(copy.copyReportButton, systemImage: "doc.on.doc")
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
                                Text(copy.repairableBadge)
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

    private var handoffPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(copy.mobileHandoffTitle, systemImage: "iphone.and.arrow.forward")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    Task { await refreshHandoff() }
                } label: {
                    if isHandoffBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(copy.refreshButton, systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isHandoffBusy)
            }

            Text(copy.mobileHandoffPrivacyWarning)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.69, green: 0.22, blue: 0.18))

            if let handoffError {
                Text(handoffError)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.69, green: 0.22, blue: 0.18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            } else if let handoffReport {
                if handoffReport.entries.isEmpty {
                    Text(copy.mobileHandoffEmpty)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 10) {
                        ForEach(handoffReport.entries) { entry in
                            HandoffEntryRow(entry: entry, copy: copy)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text(copy.mobileHandoffFileLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(handoffReport.file)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            } else {
                Text(copy.checkingValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
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
                    Text(copy.pairingQRTitle)
                        .font(.system(size: 18, weight: .bold))
                    Text(copy.pairingQRWarning)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.69, green: 0.22, blue: 0.18))
                    Text(report?.endpoint ?? "")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            copyQRImage()
                        } label: {
                            Label(copy.copyQRImageButton, systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            revealQRImage()
                        } label: {
                            Label(copy.revealQRImageButton, systemImage: "finder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer()
            }
            .padding(18)
            .background { panelBackground }
        }
    }

    private var versionText: String {
        guard let report else { return copy.checkingValue }
        if let bridgeVersion = report.bridge?.bridgeVersion {
            return "\(bridgeVersion) / \(report.packageVersion)"
        }
        return report.packageVersion
    }

    private var nextStepTitle: String {
        guard let report else { return copy.checkingValue }
        guard report.primaryAction != "none" else { return copy.readyNextStepTitle }
        return copy.recommendedActionTitle(report.primaryAction)
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

    private func refreshHandoff() async {
        isHandoffBusy = true
        defer { isHandoffBusy = false }
        do {
            handoffReport = try await runner.mobileHandoff(limit: 5)
            handoffError = nil
        } catch {
            handoffError = error.localizedDescription
        }
    }

    private func perform(_ action: ControlCenterAction) async {
        await runBusy {
            report = try await runner.run(action)
        }
    }

    private func performPrimaryAction(_ action: String) async {
        switch action {
        case "repair":
            await perform(.repair)
        case "start":
            await perform(.start)
        case "stop":
            await perform(.stop)
        case "restart":
            await perform(.restart)
        default:
            await refresh()
        }
    }

    private func pairingQR() async {
        let url = URL(fileURLWithPath: "/tmp/maludex-pairing.png")
        await runBusy {
            report = try await runner.run(.pairingQR(url))
            qrImage = NSImage(contentsOf: url)
            qrImageURL = url
        }
    }

    private func rotateToken() async {
        let url = URL(fileURLWithPath: "/tmp/maludex-pairing.png")
        await runBusy {
            report = try await runner.run(.rotateToken(url))
            qrImage = NSImage(contentsOf: url)
            qrImageURL = url
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
            Task {
                await refresh()
                await refreshHandoff()
            }
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

    private func copyQRImage() {
        guard let qrImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([qrImage])
    }

    private func revealQRImage() {
        guard let qrImageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([qrImageURL])
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

private struct HandoffEntryRow: View {
    let entry: MobileHandoffEntry
    let copy: ControlCenterCopy
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.kind)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.02, green: 0.45, blue: 0.40))
                Text(entry.createdAt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(copy.mobileHandoffThreadLabel) \(entry.shortThreadId)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(isExpanded ? entry.prompt : entry.promptPreview())
                .font(.system(size: 14, weight: .medium))
                .lineLimit(isExpanded ? nil : 4)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? copy.collapsePromptButton : copy.expandPromptButton, systemImage: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.prompt, forType: .string)
                } label: {
                    Label(copy.copyPromptButton, systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(red: 0.02, green: 0.45, blue: 0.40))

            HStack(spacing: 12) {
                if let cwd = entry.cwd, !cwd.isEmpty {
                    HandoffMetadataChip(label: copy.mobileHandoffCwdLabel, value: cwd)
                }
                if let model = entry.model, !model.isEmpty {
                    HandoffMetadataChip(label: copy.mobileHandoffModelLabel, value: model)
                }
                if !entry.attachments.isEmpty {
                    HandoffMetadataChip(
                        label: copy.mobileHandoffAttachmentsLabel,
                        value: "\(entry.attachments.count)"
                    )
                }
            }

            if !entry.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.attachments) { attachment in
                        Label(
                            "\(attachment.filename) · \(attachment.kind) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.bytes), countStyle: .file))",
                            systemImage: attachment.kind == "image" ? "photo" : "doc"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HandoffMetadataChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.55), in: Capsule())
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(tint.opacity(disabled ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 12))
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }
}
