import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import Speech

@MainActor
final class SpeechInputController: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published var transcript = ""
    @Published private(set) var statusText: String?

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var seed = ""

    override init() {
        let availableLocales = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        let localeIdentifier = preferredSpeechLocaleIdentifier(availableLocaleIdentifiers: availableLocales)
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        super.init()
    }

    func start(seed: String) {
        guard !isListening else { return }
        self.seed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = seed
        statusText = "Listening..."

        Task {
            let allowed = await requestPermissions()
            guard allowed else {
                statusText = "Microphone or speech permission is not enabled."
                return
            }

            do {
                try startRecognition()
            } catch {
                statusText = error.localizedDescription
                stop()
            }
        }
    }

    func stop() {
        guard isListening || audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isListening = false
        statusText = nil
    }

    private func requestPermissions() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAllowed else { return false }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func startRecognition() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechInputError.recognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let recognized = result.bestTranscription.formattedString
                    if self.seed.isEmpty {
                        self.transcript = recognized
                    } else if recognized.isEmpty {
                        self.transcript = self.seed
                    } else {
                        self.transcript = "\(self.seed) \(recognized)"
                    }
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }
}

private enum SpeechInputError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Korean speech recognition is not available on this device."
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairingText = ""
    @State private var scannerPresented = false
    @State private var attemptedSavedConnect = false

    var body: some View {
        NavigationStack {
            Group {
                if bridge.isConnected {
                    ProjectScreen()
                } else {
                    PairingScreen(
                        pairingText: $pairingText,
                        scannerPresented: $scannerPresented,
                        connect: connect
                    )
                }
            }
            .navigationTitle(Brand.name)
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppPalette.accent)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    ConnectionStatusPill(state: bridge.connectionState)
                }
            }
            .alert(bridge.copy.maludexBridgeTitle, isPresented: errorBinding) {
                Button(bridge.copy.okButton) {
                    bridge.lastError = nil
                }
            } message: {
                Text(bridge.lastError ?? "")
            }
            .sheet(isPresented: $scannerPresented) {
                QRCodeScannerView { code in
                    pairingText = code
                    scannerPresented = false
                    connect(payload: code)
                }
                .ignoresSafeArea()
            }
            .onAppear {
                bridge.setAppIsActive(scenePhase == .active)
                guard !attemptedSavedConnect else { return }
                attemptedSavedConnect = true
                bridge.connectSavedPairingIfAvailable()
            }
            .onChange(of: scenePhase) { _, phase in
                bridge.setAppIsActive(phase == .active)
                if phase == .active {
                    bridge.resumeConnectionIfNeeded()
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { bridge.lastError != nil },
            set: { showing in
                if !showing {
                    bridge.lastError = nil
                }
            }
        )
    }

    private func connect() {
        connect(payload: pairingText)
    }

    private func connect(payload: String) {
        do {
            bridge.connect(pairing: try Pairing(uri: payload))
        } catch {
            bridge.lastError = error.localizedDescription
        }
    }
}

private struct PairingScreen: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Binding var pairingText: String
    @Binding var scannerPresented: Bool
    let connect: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BrandLockup()
                    .padding(.top, 8)

                Picker(bridge.copy.languageLabel, selection: $bridge.selectedLanguageCode) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                ConnectionPanel(state: bridge.connectionState)

                if !bridge.savedBridges.isEmpty {
                    SavedBridgeList(
                        bridges: bridge.savedBridges,
                        activeBridgeId: bridge.activeBridgeId,
                        connect: bridge.connectSavedBridge,
                        forget: bridge.forgetSavedBridge,
                        forgetAll: {
                            bridge.forgetSavedDeviceState()
                            pairingText = ""
                        }
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label(bridge.copy.pairingPayloadTitle, systemImage: "link.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)

                    TextField("maludex://pair?host=...", text: $pairingText, axis: .vertical)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .lineLimit(4...8)
                        .padding(12)
                        .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AppPalette.line, lineWidth: 1)
                        )

                    HStack(spacing: 12) {
                        Button {
                            scannerPresented = true
                        } label: {
                            Label(bridge.copy.scanButton, systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            connect()
                        } label: {
                            Label(bridge.copy.connectButton, systemImage: "bolt.horizontal")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .controlSize(.large)
                }
                .panelStyle()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(AppPalette.background)
    }
}

private struct ProjectScreen: View {
    @EnvironmentObject private var bridge: BridgeClient
    @State private var prompt = ""
    @State private var attachments: [MobileAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var fileImporterPresented = false
    @State private var newProjectPresented = false
    @State private var chatListPresented = false
    @State private var settingsPresented = false
    @State private var subagentPresented = false
    @State private var bridgeSwitcherPresented = false
    @State private var diagnosticsPresented = false
    @State private var controlsExpanded = false
    @State private var chromeHidden = false
    @State private var historyAnchorId: TranscriptEntry.ID?
    @State private var canLoadOlderTranscript = false
    @StateObject private var speech = SpeechInputController()
    @FocusState private var promptFocused: Bool

    private let maxAttachments = 5
    private let maxAttachmentBytes = 15 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            if !chromeHidden || controlsExpanded {
                ProjectFloatingHeader(
                    isExpanded: $controlsExpanded,
                    showChats: { chatListPresented = true },
                    showNewProject: { newProjectPresented = true },
                    showSettings: { settingsPresented = true },
                    showSubagent: { subagentPresented = true },
                    showBridges: { bridgeSwitcherPresented = true },
                    showDiagnostics: { diagnosticsPresented = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TranscriptView(
                            entries: bridge.transcript,
                            hasOlder: bridge.hasOlderTranscript,
                            isLoadingOlder: bridge.isLoadingOlderTranscript,
                            loadOlder: {
                                if canLoadOlderTranscript {
                                    bridge.loadOlderTranscript()
                                }
                            }
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        promptFocused = false
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            updateChromeVisibility(forDragTranslation: value.translation.height)
                        }
                )
                .onChange(of: bridge.transcript.count) { _, _ in
                    if let historyAnchorId {
                        proxy.scrollTo(historyAnchorId, anchor: .top)
                        self.historyAnchorId = nil
                        return
                    }
                    if let last = bridge.transcript.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            canLoadOlderTranscript = true
                        }
                    }
                }
                .onChange(of: bridge.isLoadingOlderTranscript) { _, isLoading in
                    if isLoading {
                        historyAnchorId = bridge.transcript.first?.id
                    }
                }
                .onChange(of: bridge.threadId) { _, _ in
                    canLoadOlderTranscript = false
                    historyAnchorId = nil
                    showChrome()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.background)
        .safeAreaInset(edge: .bottom) {
            if shouldShowBottomChrome {
                VStack(spacing: 0) {
                    if !bridge.promptQueue.isEmpty {
                        PromptQueuePanel(
                            items: bridge.promptQueue,
                            moveUp: { bridge.moveQueuedPrompt($0, direction: -1) },
                            moveDown: { bridge.moveQueuedPrompt($0, direction: 1) },
                            cancel: { bridge.cancelQueuedPrompt($0) }
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }

                    if let approval = bridge.approvals.first {
                        ApprovalCard(approval: approval)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }

                    PromptComposer(
                        prompt: $prompt,
                        promptFocused: $promptFocused,
                        attachments: $attachments,
                        photoItems: $photoItems,
                        fileImporterPresented: $fileImporterPresented,
                        voiceState: speech,
                        toggleVoice: toggleVoice,
                        send: sendPrompt,
                        steer: steerPrompt
                    )
                }
                .background(AppPalette.panel)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.18), value: chromeHidden)
        .sheet(isPresented: $newProjectPresented) {
            NewProjectSheet()
        }
        .sheet(isPresented: $chatListPresented) {
            ChatListSheet()
        }
        .sheet(isPresented: $settingsPresented) {
            SessionSettingsSheet()
        }
        .sheet(isPresented: $subagentPresented) {
            SubagentSheet()
        }
        .sheet(isPresented: $bridgeSwitcherPresented) {
            BridgeSwitcherSheet()
        }
        .sheet(isPresented: $diagnosticsPresented) {
            DiagnosticsSheet()
        }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                loadFiles(urls)
            case .failure(let error):
                bridge.lastError = error.localizedDescription
            }
        }
        .onChange(of: photoItems) { _, items in
            loadPhotos(items)
        }
        .onChange(of: speech.transcript) { _, text in
            prompt = text
        }
        .onChange(of: promptFocused) { _, isFocused in
            if isFocused {
                showChrome()
            }
        }
    }

    private var shouldShowBottomChrome: Bool {
        !chromeHidden || promptFocused || !prompt.isEmpty || !attachments.isEmpty || !bridge.approvals.isEmpty
    }

    private func updateChromeVisibility(forDragTranslation translationY: CGFloat) {
        if translationY < -24 {
            guard !promptFocused, prompt.isEmpty, attachments.isEmpty, bridge.approvals.isEmpty else {
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                controlsExpanded = false
                chromeHidden = true
            }
        } else if translationY > 18 {
            showChrome()
        }
    }

    private func showChrome() {
        withAnimation(.easeInOut(duration: 0.18)) {
            chromeHidden = false
        }
    }

    private func sendPrompt() {
        speech.stop()
        bridge.sendTurn(
            prompt: prompt,
            attachments: attachments,
            cwd: bridge.selectedProjectPath,
            model: bridge.selectedModel
        )
        prompt = ""
        attachments.removeAll()
    }

    private func steerPrompt() {
        speech.stop()
        bridge.steerTurn(
            prompt: prompt,
            attachments: attachments,
            cwd: bridge.selectedProjectPath
        )
        prompt = ""
        attachments.removeAll()
        promptFocused = false
    }

    private func toggleVoice() {
        if speech.isListening {
            speech.stop()
        } else {
            speech.start(seed: prompt)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var loaded: [MobileAttachment] = []
            for item in items {
                if attachments.count + loaded.count >= maxAttachments {
                    break
                }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    continue
                }
                guard data.count <= maxAttachmentBytes else {
                    await MainActor.run {
                        bridge.lastError = "Attachment is larger than 15 MB."
                    }
                    continue
                }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                loaded.append(
                    MobileAttachment(
                        kind: .image,
                        filename: "photo-\(attachmentTimestamp()).\(ext)",
                        mimeType: mime,
                        data: data
                    )
                )
            }
            await MainActor.run {
                attachments.append(contentsOf: loaded)
                photoItems.removeAll()
            }
        }
    }

    private func loadFiles(_ urls: [URL]) {
        for url in urls {
            if attachments.count >= maxAttachments {
                bridge.lastError = "At most 5 attachments are allowed."
                return
            }
            let allowed = url.startAccessingSecurityScopedResource()
            defer {
                if allowed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                guard data.count <= maxAttachmentBytes else {
                    bridge.lastError = "Attachment is larger than 15 MB."
                    continue
                }
                let type = UTType(filenameExtension: url.pathExtension)
                let kind: MobileAttachment.Kind = type?.conforms(to: .image) == true ? .image : .file
                attachments.append(
                    MobileAttachment(
                        kind: kind,
                        filename: url.lastPathComponent,
                        mimeType: type?.preferredMIMEType,
                        data: data
                    )
                )
            } catch {
                bridge.lastError = error.localizedDescription
            }
        }
    }
}

private struct ProjectFloatingHeader: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Binding var isExpanded: Bool
    let showChats: () -> Void
    let showNewProject: () -> Void
    let showSettings: () -> Void
    let showSubagent: () -> Void
    let showBridges: () -> Void
    let showDiagnostics: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProjectIdentity()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()

                Spacer(minLength: 4)

                ProjectHeaderIconButton(
                    title: bridge.copy.chatsTitle,
                    systemImage: "bubble.left.and.text.bubble.right",
                    action: showChats
                )

                ProjectHeaderIconButton(
                    title: isExpanded ? bridge.copy.hideControlsTitle : bridge.copy.showControlsTitle,
                    systemImage: isExpanded ? "chevron.up" : "slider.horizontal.3"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }

                ProjectHeaderIconButton(
                    title: bridge.copy.sessionTitle,
                    systemImage: "gearshape",
                    action: showSettings
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppPalette.line, lineWidth: 1)
            )
            .shadow(color: AppPalette.panelShadow, radius: 10, x: 0, y: 5)

            if isExpanded {
                ProjectControlPanel(
                    showNewProject: showNewProject,
                    showSettings: showSettings,
                    showSubagent: showSubagent,
                    showBridges: showBridges,
                    showDiagnostics: showDiagnostics
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, isExpanded ? 8 : 5)
        .background(AppPalette.background.opacity(0.96))
        .frame(maxWidth: .infinity)
    }
}

private struct ProjectIdentity: View {
    @EnvironmentObject private var bridge: BridgeClient

    var body: some View {
        HStack(spacing: 8) {
            BrandMark(size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(Brand.name)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
                    .allowsTightening(true)

                Text(bridge.activeBridgeLabel)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectHeaderIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 40, height: 40)
                .background(AppPalette.userBubble, in: Circle())
                .overlay(Circle().stroke(AppPalette.line, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(title)
    }
}

private struct ProjectControlPanel: View {
    @EnvironmentObject private var bridge: BridgeClient
    let showNewProject: () -> Void
    let showSettings: () -> Void
    let showSubagent: () -> Void
    let showBridges: () -> Void
    let showDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ProjectHeaderIconButton(title: bridge.copy.diagnosticsTitle, systemImage: "stethoscope", action: showDiagnostics)
                    ProjectHeaderIconButton(title: bridge.copy.bridgesTitle, systemImage: "desktopcomputer", action: showBridges)
                    ProjectHeaderIconButton(title: bridge.copy.subagentTitle, systemImage: "person.2.wave.2", action: showSubagent)
                        .disabled(bridge.threadId.isEmpty)
                    ProjectHeaderIconButton(title: bridge.copy.settingsTitle, systemImage: "slider.horizontal.3", action: showSettings)
                    ProjectHeaderIconButton(title: bridge.copy.disconnectTitle, systemImage: "power") {
                        bridge.disconnect()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                Text(bridge.copy.activeBridgeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(bridge.activeBridgeLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)

                Text(bridge.copy.activeThreadTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(bridge.threadId.isEmpty ? bridge.copy.noActiveThread : bridge.threadId)
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Picker(bridge.copy.projectTitle, selection: $bridge.selectedProjectPath) {
                        if bridge.projects.isEmpty {
                            Text(bridge.copy.noProjectsTitle).tag("")
                        }
                        ForEach(bridge.projects) { project in
                            Text(project.name).tag(project.path)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .controlLabelStyle(bridge.copy.projectTitle, systemImage: "folder")

                    Button {
                        bridge.refreshProjects()
                    } label: {
                        Label(bridge.copy.refreshProjectsTitle, systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(bridge.copy.refreshProjectsTitle)

                    Button {
                        showNewProject()
                    } label: {
                        Label(bridge.copy.newProjectTitle, systemImage: "folder.badge.plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(bridge.copy.newProjectTitle)
                }

                Text(bridge.selectedProjectPath.isEmpty ? bridge.copy.selectProjectPrompt : bridge.selectedProjectPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Picker(bridge.copy.modelTitle, selection: $bridge.selectedModel) {
                        if bridge.models.isEmpty {
                            Text(bridge.copy.defaultModelTitle).tag("")
                        }
                        ForEach(bridge.models) { model in
                            Text(model.displayName).tag(model.model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .controlLabelStyle(bridge.copy.modelTitle, systemImage: "cpu")

                    if bridge.selectedModelOption?.supportsImages == true {
                        Image(systemName: "photo")
                            .foregroundStyle(AppPalette.success)
                            .accessibilityLabel(bridge.copy.supportsImagesTitle)
                    }

                    Button {
                        bridge.refreshModels()
                    } label: {
                        Label(bridge.copy.refreshModelsTitle, systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(bridge.copy.refreshModelsTitle)
                }

                HStack(spacing: 8) {
                    Label(bridge.copy.reasoningTitle(bridge.selectedReasoningEffort), systemImage: "dial.high")
                    Spacer()
                    Text("\(bridge.copy.sandboxTitle(bridge.selectedSandbox)) · \(bridge.copy.approvalPolicyTitle(bridge.selectedApprovalPolicy))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))

                Button {
                    bridge.startThread(cwd: bridge.selectedProjectPath, model: bridge.selectedModel)
                } label: {
                    Label(bridge.copy.startThreadTitle, systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!bridge.canStartProject || bridge.selectedProjectPath.isEmpty)
            }
        }
        .panelStyle()
    }
}

private struct ChatListSheet: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(bridge.chats) { chat in
                    Button {
                        bridge.openChat(threadId: chat.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(chat.title)
                                    .font(.headline)
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(1)
                                Spacer()
                                if let updatedAt = chat.updatedAt {
                                    Text(relativeTime(updatedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !chat.preview.isEmpty {
                                Text(chat.preview)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            if !chat.cwd.isEmpty {
                                Text(chat.cwd)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(bridge.copy.chatsTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bridge.copy.closeButton) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        bridge.refreshChats()
                    } label: {
                        Label(bridge.copy.refreshButton, systemImage: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                bridge.refreshChats()
            }
        }
    }
}

private struct BridgeSwitcherSheet: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(bridge.savedBridges) { saved in
                        Button {
                            bridge.connectSavedBridge(id: saved.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: saved.id == bridge.activeBridgeId ? "checkmark.circle.fill" : "desktopcomputer")
                                    .foregroundStyle(saved.id == bridge.activeBridgeId ? AppPalette.success : AppPalette.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(saved.label)
                                        .font(.headline)
                                        .foregroundStyle(AppPalette.ink)
                                    Text(saved.endpoint)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                bridge.forgetSavedBridge(id: saved.id)
                            } label: {
                                Label(bridge.copy.forgetTitle, systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text(bridge.copy.pairAnotherPCSubtitle)
                }
            }
            .navigationTitle(bridge.copy.bridgesTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bridge.copy.closeButton) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DiagnosticsSheet: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(bridge.copy.diagnosticsConnectionTitle) {
                    DiagnosticRow(title: bridge.copy.appVersionTitle, value: maludexClientVersion)
                    DiagnosticRow(title: bridge.copy.notificationsTitle, value: bridge.copy.notificationStatusTitle(bridge.notificationAuthorizationStatus.rawValue))
                    DiagnosticRow(title: bridge.copy.stateTitle, value: bridge.copy.connectionState(bridge.connectionState.rawValue))
                    DiagnosticRow(title: bridge.copy.bridgeTitle, value: bridge.activeBridgeLabel)
                    DiagnosticRow(title: bridge.copy.activeThreadTitle, value: bridge.threadId.isEmpty ? bridge.copy.noActiveThread : bridge.threadId)
                }

                if let diagnostics = bridge.diagnostics {
                    Section(bridge.copy.bridgeTitle) {
                        DiagnosticRow(title: bridge.copy.bridgeVersionTitle, value: diagnostics.bridgeVersion)
                        DiagnosticRow(title: bridge.copy.endpointTitle, value: diagnostics.endpoint)
                        DiagnosticRow(title: bridge.copy.protocolTitle, value: "\(diagnostics.protocolVersion)")
                        DiagnosticRow(title: bridge.copy.tokenFileTitle, value: diagnostics.tokenFileValid ? "valid" : "check required")
                        DiagnosticRow(title: bridge.copy.codexTitle, value: diagnostics.codexRunning ? "running" : "not running")
                    }

                    Section(bridge.copy.runtimeTitle) {
                        DiagnosticRow(title: bridge.copy.connectedClientTitle, value: diagnostics.connectedClient ? "yes" : "no")
                        DiagnosticRow(title: bridge.copy.activeTurnsTitle, value: "\(diagnostics.activeTurnCount)")
                        DiagnosticRow(title: bridge.copy.pendingApprovalsTitle, value: "\(diagnostics.pendingApprovalCount)")
                        DiagnosticRow(title: bridge.copy.eventBufferTitle, value: "\(diagnostics.eventBufferSize)/\(diagnostics.eventReplayLimit)")
                        DiagnosticRow(title: bridge.copy.projectRootsTitle, value: "\(diagnostics.projectRootCount)")
                        DiagnosticRow(title: bridge.copy.uptimeTitle, value: durationText(diagnostics.uptimeSeconds))
                    }

                    if !diagnostics.activeTurns.isEmpty {
                        Section(bridge.copy.activeTurnsTitle) {
                            ForEach(diagnostics.activeTurns, id: \.turnId) { turn in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(turn.turnId)
                                        .font(.subheadline.weight(.semibold))
                                    Text(turn.threadId)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if !diagnostics.pendingApprovals.isEmpty {
                        Section(bridge.copy.pendingApprovalsTitle) {
                            ForEach(diagnostics.pendingApprovals, id: \.approvalId) { approval in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(approval.method)
                                        .font(.subheadline.weight(.semibold))
                                    Text(approval.approvalId)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    Section(bridge.copy.reportTitle) {
                        Text(diagnostics.diagnosticReport)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = diagnostics.diagnosticReport
                        } label: {
                            Label(bridge.copy.copyReportTitle, systemImage: "doc.on.doc")
                        }
                    }
                } else {
                    Section {
                        Text(bridge.copy.noDiagnosticsTitle)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(bridge.copy.recoveryTitle) {
                    RecoveryHint(
                        title: bridge.copy.cannotConnectTitle,
                        detail: bridge.copy.cannotConnectDetail
                    )
                    RecoveryHint(
                        title: bridge.copy.authFailedTitle,
                        detail: bridge.copy.authFailedDetail
                    )
                    RecoveryHint(
                        title: bridge.copy.codexNotRunningTitle,
                        detail: bridge.copy.codexNotRunningDetail
                    )
                }
            }
            .navigationTitle(bridge.copy.diagnosticsTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bridge.copy.closeButton) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        bridge.refreshDiagnostics()
                    } label: {
                        Label(bridge.copy.refreshButton, systemImage: "arrow.clockwise")
                    }
                    .disabled(!bridge.isConnected)
                }
            }
            .onAppear {
                bridge.refreshDiagnostics()
            }
        }
    }
}

private struct DiagnosticRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct RecoveryHint: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct NewProjectSheet: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.dismiss) private var dismiss
    @State private var root = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker(bridge.copy.locationTitle, selection: $root) {
                    ForEach(bridge.projectRoots) { root in
                        Text(root.name).tag(root.path)
                    }
                }

                TextField(bridge.copy.projectNamePlaceholder, text: $name)
                    .textInputAutocapitalization(.words)
            }
            .navigationTitle(bridge.copy.newProjectTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bridge.copy.cancelButton) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bridge.copy.createButton) {
                        bridge.createProject(root: root, name: name)
                        dismiss()
                    }
                    .disabled(root.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if root.isEmpty {
                    root = bridge.projectRoots.first?.path ?? ""
                }
            }
        }
    }
}

private struct SessionSettingsSheet: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(bridge.copy.settingsTitle) {
                    Picker(bridge.copy.languageLabel, selection: $bridge.selectedLanguageCode) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(bridge.copy.modelTitle) {
                    Picker(bridge.copy.modelTitle, selection: $bridge.selectedModel) {
                        if bridge.models.isEmpty {
                            Text(bridge.copy.defaultModelTitle).tag("")
                        }
                        ForEach(bridge.models) { model in
                            Text(model.displayName).tag(model.model)
                        }
                    }

                    Picker(bridge.copy.intelligenceTitle, selection: $bridge.selectedReasoningEffort) {
                        ForEach(bridge.availableReasoningEfforts, id: \.self) { effort in
                            Text(bridge.copy.reasoningTitle(effort)).tag(effort)
                        }
                    }

                    Toggle(bridge.copy.autoCompactTitle, isOn: $bridge.autoCompactEnabled)

                    if bridge.autoCompactEnabled {
                        Stepper(
                            bridge.copy.limitTitle(thousands: bridge.autoCompactTokenLimit / 1000),
                            value: $bridge.autoCompactTokenLimit,
                            in: 20_000...200_000,
                            step: 10_000
                        )
                    }

                    Button {
                        bridge.compactThread()
                    } label: {
                        Label(bridge.copy.compactNowTitle, systemImage: "rectangle.compress.vertical")
                    }
                    .disabled(bridge.threadId.isEmpty)
                }

                Section(bridge.copy.permissionsTitle) {
                    Picker(bridge.copy.filesTitle, selection: $bridge.selectedSandbox) {
                        ForEach(SandboxOption.allCases) { option in
                            Text(bridge.copy.sandboxTitle(option.rawValue)).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(bridge.copy.approvalsTitle, selection: $bridge.selectedApprovalPolicy) {
                        ForEach(ApprovalPolicyOption.allCases) { option in
                            Text(bridge.copy.approvalPolicyTitle(option.rawValue)).tag(option.rawValue)
                        }
                    }

                    Text(bridge.copy.mobileSecurityNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(bridge.copy.sessionTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(bridge.copy.doneButton) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                bridge.refreshModels()
            }
        }
    }
}

private struct SubagentSheet: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.dismiss) private var dismiss
    @State private var role = SubagentRoleOption.worker.rawValue
    @State private var task = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker(bridge.copy.roleTitle, selection: $role) {
                    ForEach(SubagentRoleOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }

                TextEditor(text: $task)
                    .frame(minHeight: 160)
                    .textInputAutocapitalization(.sentences)
                    .textSelection(.enabled)
            }
            .navigationTitle(bridge.copy.subagentTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bridge.copy.cancelButton) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bridge.copy.startButton) {
                        bridge.startSubagent(role: role, task: task)
                        dismiss()
                    }
                    .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.threadId.isEmpty)
                }
            }
        }
    }
}

private struct TranscriptView: View {
    @EnvironmentObject private var bridge: BridgeClient
    let entries: [TranscriptEntry]
    let hasOlder: Bool
    let isLoadingOlder: Bool
    let loadOlder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(bridge.copy.conversationTitle)
                    .font(.headline)
                Spacer()
            }

            if entries.isEmpty {
                EmptyTranscriptView()
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if hasOlder || isLoadingOlder {
                        OlderTranscriptLoader(isLoading: isLoadingOlder)
                            .onAppear {
                                loadOlder()
                            }
                    }
                    ForEach(entries) { entry in
                        TranscriptBubble(entry: entry)
                            .id(entry.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OlderTranscriptLoader: View {
    let isLoading: Bool

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
            Spacer()
        }
        .frame(height: isLoading ? 28 : 8)
    }
}

private struct EmptyTranscriptView: View {
    @EnvironmentObject private var bridge: BridgeClient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bridge.copy.noTranscriptTitle)
                .font(.subheadline.weight(.semibold))
            Text(bridge.copy.noTranscriptSubtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }
}

private struct TranscriptBubble: View {
    @EnvironmentObject private var bridge: BridgeClient
    let entry: TranscriptEntry
    @State private var expanded = false

    var body: some View {
        bubbleContent
            .padding(12)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(border, lineWidth: 1)
            )
            .shadow(color: AppPalette.bubbleShadow, radius: 8, x: 0, y: 4)
            .frame(maxWidth: entry.role == .user ? 320 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.leading, entry.role == .user ? 36 : 0)
            .padding(.trailing, entry.role == .user ? 0 : 24)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if entry.isStreaming {
                    Text(bridge.copy.streamingTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !entry.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = entry.text
                    } label: {
                        Label(bridge.copy.copyTitle, systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(bridge.copy.copyTextTitle)
                }
            }

            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(isCollapsed ? 6 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if canCollapse {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(expanded ? bridge.copy.collapseTitle : bridge.copy.expandTitle, systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.accent)
                    .accessibilityLabel(expanded ? bridge.copy.collapseMessageTitle : bridge.copy.expandMessageTitle)
                }
            }

            TranscriptAttachmentGrid(attachments: entry.attachments)

            HStack {
                if entry.role == .user {
                    Spacer(minLength: 0)
                }
                Text(messageRelativeTime(from: entry.createdAt))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.role != .user {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var label: String {
        switch entry.role {
        case .user:
            return bridge.copy.youLabel
        case .assistant:
            return Brand.name
        case .system:
            return bridge.copy.threadLabel
        }
    }

    private var canCollapse: Bool {
        !entry.isStreaming && (entry.text.count > 360 || entry.text.split(separator: "\n").count > 8)
    }

    private var isCollapsed: Bool {
        canCollapse && !expanded
    }

    private var alignment: Alignment {
        entry.role == .user ? .trailing : .leading
    }

    private var labelColor: Color {
        switch entry.role {
        case .user:
            return AppPalette.accent
        case .assistant:
            return AppPalette.ink
        case .system:
            return .secondary
        }
    }

    private var background: Color {
        switch entry.role {
        case .user:
            return AppPalette.userBubble
        case .assistant:
            return AppPalette.assistantBubble
        case .system:
            return AppPalette.systemBubble
        }
    }

    private var border: Color {
        entry.role == .user ? AppPalette.accent.opacity(0.22) : AppPalette.line
    }
}

private struct TranscriptAttachmentGrid: View {
    let attachments: [TranscriptAttachment]

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(attachments) { attachment in
                    TranscriptAttachmentView(attachment: attachment)
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct TranscriptAttachmentView: View {
    let attachment: TranscriptAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if attachment.kind == .image,
               let image = attachment.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppPalette.line, lineWidth: 1)
                    )
            }

            HStack(spacing: 8) {
                Image(systemName: attachment.kind == .image ? "photo" : "doc")
                    .foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(attachment.detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppPalette.line, lineWidth: 1)
            )
        }
    }
}

private struct ApprovalCard: View {
    @EnvironmentObject private var bridge: BridgeClient
    let approval: ApprovalRequest

    var body: some View {
        let isResponding = bridge.isResponding(to: approval)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label(approval.title, systemImage: "hand.raised")
                    .font(.headline)
                Spacer()
                Text(isResponding ? bridge.copy.approvalRespondingTitle : bridge.copy.pendingTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isResponding ? AppPalette.accent : AppPalette.warning)
            }

            Text(approval.detail)
                .font(.footnote.monospaced())
                .lineLimit(6)
                .textSelection(.enabled)

            if isResponding {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(bridge.copy.approvalRespondingDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let cwd = approval.cwd {
                Text(cwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Button {
                    bridge.approve(approval)
                } label: {
                    Label(bridge.copy.approveTitle, systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResponding)

                Button(role: .destructive) {
                    bridge.deny(approval)
                } label: {
                    Label(bridge.copy.denyTitle, systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isResponding)
            }
            .controlSize(.large)
        }
        .panelStyle(border: AppPalette.warning.opacity(0.38))
    }
}

private struct PromptQueuePanel: View {
    @EnvironmentObject private var bridge: BridgeClient
    let items: [PromptQueueItem]
    let moveUp: (PromptQueueItem) -> Void
    let moveDown: (PromptQueueItem) -> Void
    let cancel: (PromptQueueItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(bridge.copy.queueTitle, systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppPalette.accent)
                                .frame(width: 22, height: 22)
                                .background(AppPalette.accent.opacity(0.12), in: Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.promptPreview.isEmpty ? bridge.copy.queuedPromptTitle : item.promptPreview)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(queueDetail(item))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)

                            Button {
                                moveUp(item)
                            } label: {
                                Label(bridge.copy.moveQueuedPromptUpTitle, systemImage: "chevron.up")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            .accessibilityLabel(bridge.copy.moveQueuedPromptUpTitle)

                            Button {
                                moveDown(item)
                            } label: {
                                Label(bridge.copy.moveQueuedPromptDownTitle, systemImage: "chevron.down")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.plain)
                            .disabled(index == items.count - 1)
                            .accessibilityLabel(bridge.copy.moveQueuedPromptDownTitle)

                            Button {
                                cancel(item)
                            } label: {
                                Label(bridge.copy.cancelQueuedPromptTitle, systemImage: "xmark")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(bridge.copy.cancelQueuedPromptTitle)
                        }
                        .padding(8)
                        .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 156)
        }
        .padding(12)
        .panelStyle(border: AppPalette.accent.opacity(0.24))
    }

    private func queueDetail(_ item: PromptQueueItem) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(item.promptBytes), countStyle: .file)
        if item.attachmentCount > 0 {
            return "\(bytes) · \(item.attachmentCount) \(bridge.copy.attachmentsTitle)"
        }
        return bytes
    }
}

private struct PromptComposer: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Binding var prompt: String
    let promptFocused: FocusState<Bool>.Binding
    @Binding var attachments: [MobileAttachment]
    @Binding var photoItems: [PhotosPickerItem]
    @Binding var fileImporterPresented: Bool
    @ObservedObject var voiceState: SpeechInputController
    let toggleVoice: () -> Void
    let send: () -> Void
    let steer: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(bridge.copy.askPlaceholder(brand: Brand.name))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $prompt)
                    .focused(promptFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
            }
            .frame(minHeight: 50, maxHeight: 96)
            .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(promptFocused.wrappedValue ? AppPalette.accent.opacity(0.45) : AppPalette.line, lineWidth: 1)
            )

            AttachmentStrip(attachments: $attachments)

            HStack(spacing: 8) {
                Button {
                    bridge.stopActiveTurn()
                } label: {
                    ComposerIconLabel(systemImage: "stop.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bridge.copy.stopTitle)
                .disabled(!bridge.canSendPrompt)

                PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                    ComposerIconLabel(systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bridge.copy.photoTitle)
                .disabled(attachments.count >= 5)

                Button {
                    fileImporterPresented = true
                } label: {
                    ComposerIconLabel(systemImage: "paperclip")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bridge.copy.fileTitle)
                .disabled(attachments.count >= 5)

                Button {
                    toggleVoice()
                } label: {
                    ComposerIconLabel(
                        systemImage: voiceState.isListening ? "mic.fill" : "mic",
                        tint: voiceState.isListening ? AppPalette.warning : AppPalette.accent,
                        background: voiceState.isListening ? AppPalette.accentWarm.opacity(0.12) : AppPalette.userBubble
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voiceState.isListening ? bridge.copy.stopVoiceInputTitle : bridge.copy.voiceInputTitle)

                Spacer(minLength: 0)

                Button {
                    steer()
                    promptFocused.wrappedValue = false
                } label: {
                    ComposerIconLabel(systemImage: "arrowshape.turn.up.right", width: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bridge.copy.steerActiveTurnTitle)
                .disabled(!bridge.canSteerPrompt || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))

                Button {
                    send()
                    promptFocused.wrappedValue = false
                } label: {
                    ComposerIconLabel(systemImage: "paperplane.fill", width: 52, isPrimary: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bridge.copy.sendTitle)
                .disabled(!bridge.canSendPrompt || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
            }

            if let status = voiceState.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct ComposerIconLabel: View {
    let systemImage: String
    var width: CGFloat = 42
    var isPrimary = false
    var tint: Color = AppPalette.accent
    var background: Color = AppPalette.userBubble
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(isPrimary ? Color.white : tint)
            .frame(width: width, height: 42)
            .background(isPrimary ? AppPalette.accent : background, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(isPrimary ? Color.clear : AppPalette.line, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
    }
}

private struct AttachmentStrip: View {
    @EnvironmentObject private var bridge: BridgeClient
    @Binding var attachments: [MobileAttachment]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 6) {
                            Image(systemName: attachment.kind == .image ? "photo" : "doc")
                            Text(attachment.filename)
                                .lineLimit(1)
                            Text(byteCount(attachment.byteCount))
                                .foregroundStyle(.secondary)
                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(bridge.copy.removeAttachmentTitle)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppPalette.input, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(AppPalette.line, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }
}

private struct ConnectionPanel: View {
    @EnvironmentObject private var bridge: BridgeClient
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(bridge.copy.maludexBridgeTitle)
                    .font(.headline)
                    .foregroundStyle(AppPalette.ink)
                Text(bridge.copy.connectionState(state.rawValue))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .panelStyle()
    }

    private var icon: String {
        switch state {
        case .offline:
            return "circle.dashed"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .offline:
            return .secondary
        case .connecting:
            return AppPalette.accent
        case .connected:
            return AppPalette.success
        case .failed:
            return AppPalette.warning
        }
    }
}

private struct ConnectionStatusPill: View {
    @EnvironmentObject private var bridge: BridgeClient
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(bridge.copy.connectionState(state.rawValue))
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppPalette.panel, in: Capsule())
        .overlay(Capsule().stroke(AppPalette.line, lineWidth: 1))
    }

    private var color: Color {
        switch state {
        case .offline:
            return .secondary
        case .connecting:
            return AppPalette.accent
        case .connected:
            return AppPalette.success
        case .failed:
            return AppPalette.warning
        }
    }
}

private struct BrandLockup: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            BrandMark(size: compact ? 38 : 54)
            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                Text(Brand.name)
                    .font(compact ? .title3.weight(.heavy) : .largeTitle.weight(.heavy))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(compact ? 0.72 : 0.82)
                    .allowsTightening(true)
                Text(Brand.studio)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }
}

private struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppPalette.brandGradient)
            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: AppPalette.accent.opacity(0.18), radius: 12, x: 0, y: 6)
        .accessibilityHidden(true)
    }
}

private struct SavedBridgeList: View {
    @EnvironmentObject private var bridgeClient: BridgeClient
    let bridges: [SavedBridge]
    let activeBridgeId: String
    let connect: (String) -> Void
    let forget: (String) -> Void
    let forgetAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bridgeClient.copy.savedBridgesTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(bridgeClient.copy.savedBridgesSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(bridges) { bridge in
                    SavedBridgeRow(
                        bridge: bridge,
                        isActive: bridge.id == activeBridgeId,
                        connect: { connect(bridge.id) },
                        forget: { forget(bridge.id) }
                    )
                }
            }

            Button(role: .destructive) {
                forgetAll()
            } label: {
                Label(bridgeClient.copy.forgetAllTitle, systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
    }
}

private struct SavedBridgeRow: View {
    @EnvironmentObject private var bridgeClient: BridgeClient
    let bridge: SavedBridge
    let isActive: Bool
    let connect: () -> Void
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "desktopcomputer")
                .foregroundStyle(isActive ? AppPalette.success : AppPalette.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(bridge.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Text(bridge.endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    connect()
                } label: {
                    Label(bridgeClient.copy.connectButton, systemImage: "bolt.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(bridgeClient.copy.connectButton) \(bridge.label)")

                Button(role: .destructive) {
                    forget()
                } label: {
                    Label(bridgeClient.copy.forgetTitle, systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(bridgeClient.copy.forgetTitle) \(bridge.label)")
            }
        }
        .padding(10)
        .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

struct DemoVideoView: View {
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let totalDuration: TimeInterval = 60
            let phaseDuration = totalDuration / Double(DemoPhase.allCases.count)
            let phase = min(DemoPhase.allCases.count - 1, max(0, Int(elapsed / phaseDuration)))
            let progress = min(1, elapsed / totalDuration)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    BrandMark(size: 54)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(Brand.name)
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundStyle(AppPalette.ink)
                        Text("local-first Codex from iPhone")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 18)

                DemoStage(phase: DemoPhase.allCases[phase])

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Apache 2.0")
                        Spacer()
                        Text("github.com/malulungsoft/maludex")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppPalette.line)
                            Capsule()
                                .fill(AppPalette.brandGradient)
                                .frame(width: geometry.size.width * progress)
                        }
                    }
                    .frame(height: 8)
                }
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppPalette.background)
        }
        .onAppear {
            startedAt = Date()
        }
    }
}

private enum DemoPhase: CaseIterable {
    case localFirst
    case pairing
    case workspace
    case transcript
    case approvals
    case bridges
}

private struct DemoStage: View {
    let phase: DemoPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .localFirst:
                DemoTitle(
                    icon: "iphone.gen3",
                    title: "Remote Codex without a relay",
                    subtitle: "Your iPhone talks to your Mac. Codex stays local."
                )
                DemoBullets([
                    "No cloud relay in v1",
                    "Codex app-server stays on stdio",
                    "Authenticated mobile WebSocket only"
                ])

            case .pairing:
                DemoTitle(
                    icon: "qrcode.viewfinder",
                    title: "Pair by QR capability token",
                    subtitle: "Scan once, store the token in Keychain."
                )
                DemoPairingCard()

            case .workspace:
                DemoTitle(
                    icon: "folder.badge.gearshape",
                    title: "Pick projects and tune the session",
                    subtitle: "Workspace, model, intelligence, permissions, and compaction."
                )
                DemoWorkspaceCard()

            case .transcript:
                DemoTitle(
                    icon: "text.bubble",
                    title: "Stream the coding turn",
                    subtitle: "Prompt from iPhone, watch Codex answer live."
                )
                DemoTranscriptCard()

            case .approvals:
                DemoTitle(
                    icon: "checkmark.shield",
                    title: "Approve actions on request",
                    subtitle: "Review commands and file changes before they run."
                )
                DemoApprovalCard()

            case .bridges:
                DemoTitle(
                    icon: "desktopcomputer",
                    title: "Switch between local Macs",
                    subtitle: "Each bridge keeps its own token and session."
                )
                DemoBridgeCard()
            }
        }
    }
}

private struct DemoTitle: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 54, height: 54)
                .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))

            Text(title)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle()
    }
}

private struct DemoBullets: View {
    let bullets: [String]

    init(_ bullets: [String]) {
        self.bullets = bullets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(bullets, id: \.self) { bullet in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppPalette.success)
                    Text(bullet)
                        .font(.headline)
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                }
            }
        }
        .panelStyle()
    }
}

private struct DemoPairingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(AppPalette.success)
                Text("Bearer auth required")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                DemoKeyValue("Host", "100.x.y.z")
                DemoKeyValue("Port", "8765")
                DemoKeyValue("Token", "masked high-entropy secret")
                DemoKeyValue("Bridge", "Studio Mac")
            }

            Text("QR payloads are secrets. Do not post screenshots.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppPalette.accentWarm)
        }
        .panelStyle()
    }
}

private struct DemoWorkspaceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DemoChipRow(["maludex", "GPT-5.5", "High", "On request"])

            DemoKeyValue("Project", "~/Developer/maludex")
            DemoKeyValue("Files", "workspace-write")
            DemoKeyValue("Context", "auto compact on")

            HStack {
                Label("Start thread", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
        }
        .panelStyle()
    }
}

private struct DemoTranscriptCard: View {
    var body: some View {
        VStack(spacing: 10) {
            DemoBubble(role: "You", text: "Add a secure WebSocket bridge and stream events.", isUser: true)
            DemoBubble(role: "maludex", text: "Implemented authenticated pairing, event replay, and approval forwarding...", isUser: false)
            DemoChipRow(["image.png", "notes.md", "streaming"])
        }
        .panelStyle()
    }
}

private struct DemoApprovalCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Approval requested", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Text("on-request")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
            }

            Text("npm test")
                .font(.title3.monospaced().weight(.bold))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Deny")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
                Text("Approve")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(AppPalette.success, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .panelStyle(border: AppPalette.success.opacity(0.35))
    }
}

private struct DemoBridgeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DemoBridgeRow(name: "Studio Mac", endpoint: "ws://100.x.y.11:8765", active: true)
            DemoBridgeRow(name: "Desk PC", endpoint: "ws://100.x.y.22:8765", active: false)
            DemoBridgeRow(name: "Laptop", endpoint: "ws://100.x.y.33:8765", active: false)

            Text("Tokens are stored separately per bridge.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .panelStyle()
    }
}

private struct DemoBridgeRow: View {
    let name: String
    let endpoint: String
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "desktopcomputer")
                .foregroundStyle(active ? AppPalette.success : AppPalette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct DemoBubble: View {
    let role: String
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 30)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(role)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isUser ? AppPalette.accent : AppPalette.ink)
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: isUser ? 300 : .infinity, alignment: .leading)
            .background(isUser ? AppPalette.userBubble : AppPalette.assistantBubble, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
            if !isUser {
                Spacer(minLength: 24)
            }
        }
    }
}

private struct DemoChipRow: View {
    let chips: [String]

    init(_ chips: [String]) {
        self.chips = chips
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AppPalette.userBubble, in: Capsule())
                    .overlay(Capsule().stroke(AppPalette.accent.opacity(0.18), lineWidth: 1))
            }
        }
    }
}

private struct DemoKeyValue: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 0)
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func controlLabelStyle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 22)
            self
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppPalette.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppPalette.line, lineWidth: 1)
        )
        .accessibilityLabel(title)
    }

    func panelStyle(border: Color = AppPalette.line) -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .shadow(color: AppPalette.panelShadow, radius: 14, x: 0, y: 8)
    }
}

private enum Brand {
    static let name = "maludex"
    static let studio = "malulung soft"
}

private enum AppPalette {
    static let background = Color(red: 0.965, green: 0.964, blue: 0.944)
    static let panel = Color(red: 1.000, green: 0.996, blue: 0.972)
    static let input = Color(red: 0.985, green: 0.984, blue: 0.960)
    static let ink = Color(red: 0.075, green: 0.118, blue: 0.115)
    static let accent = Color(red: 0.045, green: 0.420, blue: 0.380)
    static let accentWarm = Color(red: 0.720, green: 0.345, blue: 0.220)
    static let success = Color(red: 0.110, green: 0.500, blue: 0.285)
    static let warning = Color(red: 0.705, green: 0.415, blue: 0.120)
    static let line = Color.black.opacity(0.085)
    static let userBubble = Color(red: 0.850, green: 0.940, blue: 0.910)
    static let assistantBubble = Color(red: 1.000, green: 0.996, blue: 0.972)
    static let systemBubble = Color(red: 0.925, green: 0.915, blue: 0.875)
    static let panelShadow = Color.black.opacity(0.055)
    static let bubbleShadow = Color.black.opacity(0.035)
    static let brandGradient = LinearGradient(
        colors: [accent, Color(red: 0.060, green: 0.285, blue: 0.520), accentWarm],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private func attachmentTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

private func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private func relativeTime(_ timestamp: Double) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
}

private func durationText(_ seconds: Int) -> String {
    if seconds < 60 {
        return "\(seconds)s"
    }
    if seconds < 3600 {
        return "\(seconds / 60)m"
    }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
}

private func reasoningTitle(_ value: String) -> String {
    ReasoningEffortOption(rawValue: value)?.title ?? value
}

private extension TranscriptAttachment {
    var previewImage: UIImage? {
        guard let previewDataBase64,
              let data = Data(base64Encoded: previewDataBase64) else {
            return nil
        }
        return UIImage(data: data)
    }

    var detailText: String {
        let typeText = mimeType ?? (kind == .image ? "image" : "file")
        if let byteCount {
            return "\(typeText) · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
        }
        return typeText
    }
}
