import Foundation
import UserNotifications

struct BridgeEvent: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

enum ConnectionState: String, Equatable {
    case offline = "Offline"
    case connecting = "Connecting"
    case connected = "Connected"
    case failed = "Connection issue"
}

enum MobileNotificationAuthorizationStatus: String, Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .unknown
        }
    }
}

struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    let method: String
    let params: [String: JSONValue]

    var command: String? {
        params["command"]?.stringValue
    }

    var cwd: String? {
        params["cwd"]?.stringValue
    }

    var requestedPermissions: JSONValue? {
        params["permissions"]
    }

    var title: String {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            return "Command approval"
        case "item/fileChange/requestApproval", "applyPatchApproval":
            return "File change approval"
        case "item/permissions/requestApproval":
            return "Permission approval"
        default:
            return "Approval request"
        }
    }

    var detail: String {
        if let command {
            return command
        }
        return JSONValue.object(params).description
    }
}

@MainActor
final class BridgeClient: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .offline
    @Published private(set) var events: [BridgeEvent] = []
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var approvals: [ApprovalRequest] = []
    @Published private(set) var respondingApprovalIds: Set<String> = []
    @Published private(set) var projects: [ProjectOption] = []
    @Published private(set) var projectRoots: [ProjectRootOption] = []
    @Published private(set) var models: [CodexModelOption] = []
    @Published private(set) var chats: [ChatThreadOption] = []
    @Published private(set) var promptQueue: [PromptQueueItem] = []
    @Published private(set) var activeTurnId: String?
    @Published private(set) var isLoadingOlderTranscript = false
    @Published private(set) var isRefreshingActiveChat = false
    @Published private(set) var lastTranscriptSyncAt: Date?
    @Published private(set) var hasOlderTranscript = false
    @Published private(set) var hasSavedPairing = false
    @Published private(set) var savedPairingLabel: String?
    @Published private(set) var savedBridges: [SavedBridge] = []
    @Published private(set) var activeBridgeId = ""
    @Published private(set) var diagnostics: BridgeDiagnostics?
    @Published private(set) var notificationAuthorizationStatus = MobileNotificationAuthorizationStatus.unknown
    @Published private(set) var customPromptTemplates: [PromptTemplate] = []
    @Published private(set) var favoriteProjectPaths: [String] = []
    @Published var selectedProjectPath = "" {
        didSet { persistSnapshot() }
    }
    @Published var selectedModel = "" {
        didSet {
            normalizeReasoningEffortForSelectedModel()
            persistSnapshot()
        }
    }
    @Published var selectedReasoningEffort = ReasoningEffortOption.fallback {
        didSet { persistSnapshot() }
    }
    @Published var selectedApprovalPolicy = ApprovalPolicyOption.onRequest.rawValue {
        didSet { persistSnapshot() }
    }
    @Published var selectedSandbox = SandboxOption.readOnly.rawValue {
        didSet { persistSnapshot() }
    }
    @Published var selectedLanguageCode = AppLanguage.fallback.rawValue {
        didSet { persistSnapshot() }
    }
    @Published var autoCompactEnabled = true {
        didSet { persistSnapshot() }
    }
    @Published var autoCompactTokenLimit = 120000 {
        didSet { persistSnapshot() }
    }
    @Published var threadId = "" {
        didSet { persistSnapshot() }
    }
    @Published var promptDraft = "" {
        didSet { persistSnapshot() }
    }
    @Published var lastError: String?

    var isConnected: Bool {
        connectionState == .connected
    }

    var canStartProject: Bool {
        connectionState == .connected
    }

    var canSendPrompt: Bool {
        connectionState == .connected && !threadId.isEmpty
    }

    var canSteerPrompt: Bool {
        canSendPrompt && activeTurnId != nil
    }

    var canRefreshActiveChat: Bool {
        connectionState == .connected
            && !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoadingOlderTranscript
            && !isRefreshingActiveChat
    }

    var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: selectedLanguageCode) ?? .fallback
    }

    var copy: AppCopy {
        AppCopy(language: selectedLanguage)
    }

    var quickPromptTemplates: [PromptTemplate] {
        PromptTemplate.mergedBuiltIns(language: selectedLanguage, custom: customPromptTemplates)
    }

    var activeThreadLabel: String {
        threadId.isEmpty ? "No active thread" : threadId
    }

    var activeBridgeLabel: String {
        if let bridge = savedBridges.first(where: { $0.id == activeBridgeId }) {
            return bridge.label
        }
        if let pairing {
            return pairing.label ?? "\(pairing.host):\(pairing.port)"
        }
        return "No bridge"
    }

    var selectedModelOption: CodexModelOption? {
        models.first { $0.model == selectedModel }
    }

    var availableReasoningEfforts: [String] {
        let values = selectedModelOption?.supportedReasoningEfforts ?? []
        return values.isEmpty ? ReasoningEffortOption.allCases.map(\.rawValue) : values
    }

    private var pairing: Pairing?
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var manuallyDisconnected = false
    private var transcriptCursor: String?
    private var nextId = 1
    private var lastEventId = 0
    private var lastActiveChatRefreshAt: Date?
    private var activeTurnLastEventAt: Date?
    private var pendingActiveChatRefreshes: [String: ActiveChatRefreshRequest] = [:]
    private var pendingApprovalResponseIds: [String: String] = [:]
    private let transcriptStore = TranscriptStore()
    private let stateStore: DeviceStateStore
    private let notificationScheduler = LocalNotificationScheduler()
    private var demoPlaybackTask: Task<Void, Never>?
    private var suppressPersistence = false
    private var appIsActive = true
    private var isDemoMode = false

    private struct ActiveChatRefreshRequest {
        let allowActiveTurnRefresh: Bool
    }

    init(stateStore: DeviceStateStore = DeviceStateStore(), demoScenario: Bool = false) {
        self.stateStore = stateStore
        if demoScenario {
            isDemoMode = true
            suppressPersistence = true
            loadDemoPairingState()
            return
        }
        restorePersistedState()
        refreshSavedPairingState()
        notificationScheduler.requestAuthorizationIfNeeded { [weak self] in
            Task { @MainActor in
                self?.refreshNotificationAuthorizationStatus()
            }
        }
        refreshNotificationAuthorizationStatus()
    }

    deinit {
        demoPlaybackTask?.cancel()
    }

    func setAppIsActive(_ isActive: Bool) {
        appIsActive = isActive
        refreshNotificationAuthorizationStatus()
        if isActive {
            refreshActiveChatIfNeeded(force: true)
        }
        if !isActive {
            schedulePendingApprovalNotifications()
        }
    }

    func startDemoPlaybackIfNeeded() {
        guard isDemoMode, demoPlaybackTask == nil else {
            return
        }
        startDemoPlayback()
    }

    func refreshNotificationAuthorizationStatus() {
        notificationScheduler.authorizationStatus { [weak self] status in
            Task { @MainActor in
                self?.notificationAuthorizationStatus = MobileNotificationAuthorizationStatus(status)
            }
        }
    }

    func refreshActiveChatNow() {
        _ = refreshActiveChatIfNeeded(
            force: true,
            allowActiveTurnRefresh: true,
            bypassMinimumInterval: true
        )
    }

    func connect(pairing: Pairing) {
        guard !isDemoMode else {
            loadConnectedDemoState()
            return
        }
        manuallyDisconnected = false
        cancelReconnect()
        closeSocket(setOffline: true)
        self.pairing = pairing
        lastActiveChatRefreshAt = nil
        activeTurnLastEventAt = nil
        pendingActiveChatRefreshes.removeAll()
        isRefreshingActiveChat = false
        do {
            try stateStore.savePairing(pairing)
            refreshSavedPairingState()
            restorePersistedState()
        } catch {
            lastError = userFacingBridgeError(["message": .string(error.localizedDescription)])
        }

        var components = URLComponents(url: pairing.websocketURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "afterEventId", value: String(lastEventId))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        connectionState = .connecting
        appendEvent("bridge", "connecting to \(pairing.host):\(pairing.port)")
        receiveLoop(for: task)
    }

    func connectSavedPairingIfAvailable() {
        guard !isDemoMode else {
            return
        }
        guard connectionState == .offline || connectionState == .failed else {
            return
        }
        do {
            guard let savedPairing = try stateStore.loadPairing() else {
                refreshSavedPairingState()
                return
            }
            connect(pairing: savedPairing)
        } catch {
            lastError = userFacingConnectionError(error.localizedDescription)
            refreshSavedPairingState()
        }
    }

    func resumeConnectionIfNeeded() {
        if connectionState == .connected {
            if !refreshActiveChatIfNeeded(force: true) {
                sendPing()
            }
            return
        }
        if connectionState == .offline || connectionState == .failed {
            connectSavedPairingIfAvailable()
        }
    }

    func connectSavedBridge(id: String) {
        guard !isDemoMode else {
            loadConnectedDemoState()
            return
        }
        guard connectionState == .offline || connectionState == .failed || connectionState == .connected else {
            return
        }
        do {
            try stateStore.selectBridge(id: id)
            restorePersistedState()
            refreshSavedPairingState()
            guard let savedPairing = try stateStore.loadPairing(id: id) else {
                lastError = "Saved bridge token is missing."
                return
            }
            connect(pairing: savedPairing)
        } catch {
            lastError = userFacingConnectionError(error.localizedDescription)
            refreshSavedPairingState()
        }
    }

    func renameSavedBridge(id: String, label: String) {
        stateStore.renameBridge(id: id, label: label)
        refreshSavedPairingState()
        if let current = pairing, current.id == id, let renamed = savedBridges.first(where: { $0.id == id }) {
            pairing = Pairing(
                host: current.host,
                port: current.port,
                token: current.token,
                usesTLS: current.usesTLS,
                label: renamed.label
            )
        }
    }

    func saveCustomPromptTemplate(id: String? = nil, title: String, prompt: String, systemImage: String) {
        let existingId = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let templateId: String
        if let existingId, !existingId.isEmpty {
            templateId = existingId
        } else {
            templateId = "custom-\(UUID().uuidString)"
        }
        let template = PromptTemplate(
            id: templateId,
            title: title,
            prompt: prompt,
            systemImage: systemImage
        )
        stateStore.saveCustomPromptTemplate(template)
        refreshCustomPromptTemplates()
    }

    func deleteCustomPromptTemplate(id: String) {
        stateStore.deleteCustomPromptTemplate(id: id)
        refreshCustomPromptTemplates()
    }

    func moveCustomPromptTemplate(id: String, direction: Int) {
        stateStore.moveCustomPromptTemplate(id: id, direction: direction)
        refreshCustomPromptTemplates()
    }

    func isFavoriteProject(_ path: String) -> Bool {
        favoriteProjectPaths.contains(path)
    }

    func toggleFavoriteProject(path: String) {
        stateStore.toggleFavoriteProject(path: path)
        refreshFavoriteProjects()
    }

    func disconnect() {
        guard !isDemoMode else {
            loadDemoPairingState()
            startDemoPlayback()
            return
        }
        manuallyDisconnected = true
        cancelReconnect()
        closeSocket(setOffline: true)
        connectionState = .offline
        approvals.removeAll()
        clearPendingApprovalResponses()
        activeTurnId = nil
        activeTurnLastEventAt = nil
    }

    func forgetSavedDeviceState() {
        let preservedLanguageCode = selectedLanguageCode
        disconnect()
        do {
            try stateStore.clear()
        } catch {
            lastError = userFacingBridgeError(["message": .string(error.localizedDescription)])
        }

        suppressPersistence = true
        pairing = nil
        selectedProjectPath = ""
        selectedModel = ""
        selectedReasoningEffort = ReasoningEffortOption.fallback
        selectedApprovalPolicy = ApprovalPolicyOption.onRequest.rawValue
        selectedSandbox = SandboxOption.readOnly.rawValue
        selectedLanguageCode = preservedLanguageCode.isEmpty ? AppLanguage.fallback.rawValue : preservedLanguageCode
        autoCompactEnabled = true
        autoCompactTokenLimit = 120000
        threadId = ""
        lastEventId = 0
        transcriptCursor = nil
        hasOlderTranscript = false
        isLoadingOlderTranscript = false
        isRefreshingActiveChat = false
        lastTranscriptSyncAt = nil
        projects.removeAll()
        projectRoots.removeAll()
        models.removeAll()
        chats.removeAll()
        customPromptTemplates.removeAll()
        favoriteProjectPaths.removeAll()
        transcriptStore.replace(with: [])
        transcript = []
        savedBridges = []
        activeBridgeId = ""
        hasSavedPairing = false
        savedPairingLabel = nil
        suppressPersistence = false
        persistSnapshot()
        refreshSavedPairingState()
    }

    func forgetSavedBridge(id: String) {
        let wasActive = id == activeBridgeId
        if wasActive {
            disconnect()
        }
        do {
            try stateStore.deleteBridge(id: id)
            restorePersistedState()
            refreshSavedPairingState()
        } catch {
            lastError = userFacingBridgeError(["message": .string(error.localizedDescription)])
        }
    }

    func startThread(cwd: String) {
        startThread(cwd: cwd, model: selectedModel)
    }

    func startThread(cwd: String, model: String) {
        var body: [String: JSONValue] = [
            "id": .string(nextMessageId()),
            "type": .string("thread.start")
        ]
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCwd.isEmpty {
            body["cwd"] = .string(trimmedCwd)
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            body["model"] = .string(trimmedModel)
        }
        appendSessionSettings(to: &body, includeAutoCompact: true)
        send(body)
    }

    func sendTurn(prompt: String) {
        sendTurn(prompt: prompt, attachments: [], cwd: selectedProjectPath, model: selectedModel)
    }

    func sendTurn(prompt: String, attachments: [MobileAttachment], cwd: String, model: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadId.isEmpty else {
            lastError = "Start a thread before sending a prompt."
            return
        }
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            return
        }

        let transcriptPrompt = trimmedPrompt.isEmpty ? "" : trimmedPrompt
        transcriptStore.addUserPrompt(transcriptPrompt, attachments: attachments.map(\.transcriptAttachment))
        publishTranscript()

        var body: [String: JSONValue] = [
            "id": .string(nextMessageId()),
            "type": .string("turn.start"),
            "threadId": .string(threadId),
            "prompt": .string(trimmedPrompt)
        ]
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCwd.isEmpty {
            body["cwd"] = .string(trimmedCwd)
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            body["model"] = .string(trimmedModel)
        }
        if !attachments.isEmpty {
            body["attachments"] = .array(attachments.map { .object($0.payload) })
        }
        appendSessionSettings(to: &body, includeAutoCompact: false)
        send(body)
    }

    func refreshProjects() {
        send([
            "id": .string(nextMessageId(prefix: "ios-projects")),
            "type": .string("project.list")
        ])
    }

    func createProject(root: String, name: String) {
        send([
            "id": .string(nextMessageId(prefix: "ios-create-project")),
            "type": .string("project.create"),
            "root": .string(root),
            "name": .string(name)
        ])
    }

    func refreshModels() {
        send([
            "id": .string(nextMessageId(prefix: "ios-models")),
            "type": .string("model.list")
        ])
    }

    func refreshChats() {
        send([
            "id": .string(nextMessageId(prefix: "ios-chats")),
            "type": .string("chat.list")
        ])
    }

    func refreshDiagnostics() {
        send([
            "id": .string(nextMessageId(prefix: "ios-status")),
            "type": .string("bridge.status")
        ])
    }

    func openChat(threadId: String) {
        transcriptCursor = nil
        hasOlderTranscript = false
        isLoadingOlderTranscript = false
        var body: [String: JSONValue] = [
            "id": .string(nextMessageId(prefix: "ios-open-chat")),
            "type": .string("chat.open"),
            "threadId": .string(threadId),
            "turnLimit": .number(30.0),
            "transcriptByteLimit": .number(Double(768 * 1024))
        ]
        if !selectedModel.isEmpty {
            body["model"] = .string(selectedModel)
        }
        appendSessionSettings(to: &body, includeAutoCompact: true)
        send(body)
    }

    func loadOlderTranscript() {
        guard !isLoadingOlderTranscript,
              hasOlderTranscript,
              let transcriptCursor,
              !threadId.isEmpty,
              connectionState == .connected else {
            return
        }
        isLoadingOlderTranscript = true
        send([
            "id": .string(nextMessageId(prefix: "ios-chat-history")),
            "type": .string("chat.history"),
            "threadId": .string(threadId),
            "cursor": .string(transcriptCursor),
            "limit": .number(30.0),
            "transcriptByteLimit": .number(Double(768 * 1024))
        ])
    }

    func compactThread() {
        guard !threadId.isEmpty else {
            lastError = "Start or open a thread before compacting context."
            return
        }
        send([
            "id": .string(nextMessageId(prefix: "ios-compact")),
            "type": .string("thread.compact"),
            "threadId": .string(threadId)
        ])
    }

    func startSubagent(role: String, task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadId.isEmpty else {
            lastError = "Open a thread before starting a subagent."
            return
        }
        guard !trimmed.isEmpty else {
            return
        }

        var body: [String: JSONValue] = [
            "id": .string(nextMessageId(prefix: "ios-subagent")),
            "type": .string("subagent.start"),
            "threadId": .string(threadId),
            "role": .string(role),
            "prompt": .string(trimmed)
        ]
        if !selectedProjectPath.isEmpty {
            body["cwd"] = .string(selectedProjectPath)
        }
        if !selectedModel.isEmpty {
            body["model"] = .string(selectedModel)
        }
        appendSessionSettings(to: &body, includeAutoCompact: false)
        send(body)
        transcriptStore.addSystemMessage("Subagent requested: \(SubagentRoleOption(rawValue: role)?.title ?? "Subagent")")
        publishTranscript()
    }

    func stopActiveTurn() {
        guard !threadId.isEmpty else {
            return
        }
        send([
            "id": .string(nextMessageId()),
            "type": .string("turn.stop"),
            "threadId": .string(threadId)
        ])
    }

    func steerTurn(prompt: String, attachments: [MobileAttachment], cwd: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let activeTurnId, !threadId.isEmpty else {
            lastError = "No active Codex turn is running for this chat."
            return
        }
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            return
        }

        transcriptStore.addUserPrompt(trimmedPrompt.isEmpty ? "" : "Steer: \(trimmedPrompt)", attachments: attachments.map(\.transcriptAttachment))
        publishTranscript()

        var body: [String: JSONValue] = [
            "id": .string(nextMessageId(prefix: "ios-steer")),
            "type": .string("turn.steer"),
            "threadId": .string(threadId),
            "turnId": .string(activeTurnId),
            "prompt": .string(trimmedPrompt)
        ]
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCwd.isEmpty {
            body["cwd"] = .string(trimmedCwd)
        }
        if !attachments.isEmpty {
            body["attachments"] = .array(attachments.map { .object($0.payload) })
        }
        send(body)
    }

    func refreshPromptQueue() {
        var body: [String: JSONValue] = [
            "id": .string(nextMessageId(prefix: "ios-queue")),
            "type": .string("queue.list")
        ]
        if !threadId.isEmpty {
            body["threadId"] = .string(threadId)
        }
        send(body, reportErrors: false)
    }

    func moveQueuedPrompt(_ item: PromptQueueItem, direction: Int) {
        guard let currentIndex = promptQueue.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        let targetIndex = max(0, min(promptQueue.count - 1, currentIndex + direction))
        guard targetIndex != currentIndex else {
            return
        }
        send([
            "id": .string(nextMessageId(prefix: "ios-queue-move")),
            "type": .string("queue.move"),
            "threadId": .string(item.threadId),
            "itemId": .string(item.id),
            "toIndex": .number(Double(targetIndex))
        ])
    }

    func cancelQueuedPrompt(_ item: PromptQueueItem) {
        send([
            "id": .string(nextMessageId(prefix: "ios-queue-cancel")),
            "type": .string("queue.cancel"),
            "threadId": .string(item.threadId),
            "itemId": .string(item.id)
        ])
    }

    func approve(_ approval: ApprovalRequest) {
        respond(to: approval, decision: "accept")
    }

    func deny(_ approval: ApprovalRequest) {
        respond(to: approval, decision: "decline")
    }

    func isResponding(to approval: ApprovalRequest) -> Bool {
        respondingApprovalIds.contains(approval.id)
    }

    private func respond(to approval: ApprovalRequest, decision: String) {
        guard !respondingApprovalIds.contains(approval.id) else {
            appendEvent("approval", "waiting for confirmation")
            return
        }
        let requestId = nextMessageId(prefix: "ios-approval")
        var body: [String: JSONValue] = [
            "id": .string(requestId),
            "type": .string("approval.respond"),
            "approvalId": .string(approval.id),
            "decision": .string(decision)
        ]

        if approval.method == "item/permissions/requestApproval",
           decision == "accept",
           let permissions = approval.requestedPermissions {
            body["permissions"] = permissions
            body["scope"] = .string("turn")
        }

        pendingApprovalResponseIds[requestId] = approval.id
        respondingApprovalIds.insert(approval.id)
        send(body)
        appendEvent("approval", "sent \(decision)")
    }

    private func appendSessionSettings(to body: inout [String: JSONValue], includeAutoCompact: Bool) {
        body["approvalPolicy"] = .string(validApprovalPolicy(selectedApprovalPolicy))
        body["sandbox"] = .string(validSandbox(selectedSandbox))
        body["reasoningEffort"] = .string(validReasoningEffort(selectedReasoningEffort))
        if includeAutoCompact && autoCompactEnabled {
            body["autoCompact"] = .bool(true)
            body["autoCompactTokenLimit"] = .number(Double(min(max(autoCompactTokenLimit, 4096), 2_000_000)))
        }
    }

    private func normalizeReasoningEffortForSelectedModel() {
        let allowed = availableReasoningEfforts
        guard !allowed.isEmpty else {
            if selectedReasoningEffort.isEmpty {
                selectedReasoningEffort = ReasoningEffortOption.fallback
            }
            return
        }
        if !allowed.contains(selectedReasoningEffort) {
            selectedReasoningEffort = selectedModelOption?.defaultReasoningEffort ?? allowed.first ?? ReasoningEffortOption.fallback
        }
    }

    private func send(_ body: [String: JSONValue], reportErrors: Bool = true) {
        guard !isDemoMode else {
            appendEvent(body["type"]?.stringValue ?? "demo", "demo mode")
            return
        }
        guard let task, connectionState == .connected else {
            if reportErrors {
                lastError = userFacingConnectionError(connectionState == .connecting ? "Bridge is still connecting." : "Bridge is not connected.")
            }
            if !manuallyDisconnected {
                scheduleReconnect()
            }
            return
        }

        do {
            let data = try JSONEncoder().encode(JSONValue.object(body))
            task.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.handleConnectionFailure(error, reportError: reportErrors)
                }
            }
        } catch {
            if reportErrors {
                lastError = userFacingBridgeError(["message": .string(error.localizedDescription)])
            }
        }
    }

    private func receiveLoop(for currentTask: URLSessionWebSocketTask) {
        currentTask.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.task === currentTask else {
                    return
                }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop(for: currentTask)
                case .failure(let error):
                    self.handleConnectionFailure(error, reportError: false)
                }
            }
        }
    }

    private func handleConnectionFailure(_ error: Error, reportError: Bool) {
        guard !manuallyDisconnected else {
            return
        }
        closeSocket(setOffline: false)
        connectionState = .failed
        approvals.removeAll()
        clearPendingApprovalResponses()
        activeTurnId = nil
        activeTurnLastEventAt = nil
        isLoadingOlderTranscript = false
        isRefreshingActiveChat = false
        appendEvent("bridge", "connection lost: \(error.localizedDescription)")
        if reportError {
            lastError = userFacingConnectionError(error.localizedDescription)
        }
        scheduleReconnect()
    }

    private func closeSocket(setOffline: Bool) {
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pendingActiveChatRefreshes.removeAll()
        isRefreshingActiveChat = false
        if setOffline {
            connectionState = .offline
        }
    }

    private func scheduleReconnect() {
        guard !manuallyDisconnected,
              reconnectTask == nil,
              pairing != nil || hasSavedPairing else {
            return
        }
        let delay = min(pow(2.0, Double(min(reconnectAttempt, 4))), 30.0)
        reconnectAttempt += 1
        appendEvent("bridge", "reconnecting in \(Int(delay))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                guard !self.manuallyDisconnected else { return }
                if let pairing = self.pairing {
                    self.connect(pairing: pairing)
                } else {
                    self.connectSavedPairingIfAvailable()
                }
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    if !self.refreshActiveChatIfNeeded() {
                        self.sendPing()
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func sendPing() {
        guard !isDemoMode else {
            return
        }
        guard connectionState == .connected else {
            return
        }
        send([
            "id": .string(nextMessageId(prefix: "ios-ping")),
            "type": .string("ping")
        ], reportErrors: false)
    }

    @discardableResult
    private func refreshActiveChatIfNeeded(
        force: Bool = false,
        allowActiveTurnRefresh: Bool = false,
        bypassMinimumInterval: Bool = false
    ) -> Bool {
        guard !isDemoMode else {
            return false
        }
        let now = Date()
        let shouldRefresh: Bool
        shouldRefresh = shouldRefreshActiveChat(
            isConnected: connectionState == .connected,
            threadId: threadId,
            isLoadingOlderTranscript: isLoadingOlderTranscript,
            hasActiveTurn: activeTurnId != nil,
            now: now,
            lastRefreshAt: force ? nil : lastActiveChatRefreshAt,
            minimumInterval: 12,
            activeTurnLastEventAt: activeTurnLastEventAt,
            activeTurnRecoveryInterval: 45,
            bypassMinimumInterval: bypassMinimumInterval,
            allowActiveTurnRefresh: allowActiveTurnRefresh
        )
        guard shouldRefresh, pendingActiveChatRefreshes.isEmpty else {
            return false
        }

        let requestId = nextMessageId(prefix: "ios-sync-chat")
        var body: [String: JSONValue] = [
            "id": .string(requestId),
            "type": .string("chat.open"),
            "threadId": .string(threadId),
            "turnLimit": .number(30.0),
            "transcriptByteLimit": .number(Double(768 * 1024))
        ]
        if !selectedModel.isEmpty {
            body["model"] = .string(selectedModel)
        }
        appendSessionSettings(to: &body, includeAutoCompact: true)
        pendingActiveChatRefreshes[requestId] = ActiveChatRefreshRequest(allowActiveTurnRefresh: allowActiveTurnRefresh)
        isRefreshingActiveChat = true
        lastActiveChatRefreshAt = now
        send(body, reportErrors: false)
        return true
    }

    private func finishActiveChatRefresh(requestId: String?) -> ActiveChatRefreshRequest? {
        let request: ActiveChatRefreshRequest?
        if let requestId {
            request = pendingActiveChatRefreshes.removeValue(forKey: requestId)
        } else {
            request = nil
        }
        if pendingActiveChatRefreshes.isEmpty {
            isRefreshingActiveChat = false
        }
        return request
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            return
        }

        do {
            guard let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
                  let type = object["type"]?.stringValue else {
                return
            }

            switch type {
            case "bridge.ready":
                connectionState = .connected
                reconnectAttempt = 0
                cancelReconnect()
                startHeartbeat()
                if let warning = bridgeCompatibilityWarning(readyMessage: object) {
                    lastError = warning
                }
                let version = object["bridgeVersion"]?.stringValue ?? "unknown"
                if let serverLastEventId = object["lastEventId"]?.intValue {
                    let normalized = normalizedReconnectEventId(current: lastEventId, serverLastEventId: serverLastEventId)
                    if normalized != lastEventId {
                        lastEventId = normalized
                        persistSnapshot()
                        appendEvent("bridge", "event cursor reset")
                    }
                }
                appendEvent("bridge", "ready \(version)")
                refreshProjects()
                refreshModels()
                refreshChats()
                refreshPromptQueue()
                refreshActiveChatIfNeeded(force: true)
            case "response":
                handleResponse(object)
            case "codex.event":
                handleCodexEvent(object)
            case "approval.requested":
                handleApproval(object)
            case "approval.responded", "approval.resolved":
                handleApprovalResolved(object)
            case "prompt.queue.updated":
                handlePromptQueueUpdated(object)
            case "prompt.queue.started":
                handlePromptQueueStarted(object)
            case "prompt.queue.failed":
                handlePromptQueueFailed(object)
            default:
                appendEvent(type, JSONValue.object(object).description)
            }
        } catch {
            lastError = userFacingBridgeError(["message": .string(error.localizedDescription)])
        }
    }

    private func handleResponse(_ object: [String: JSONValue]) {
        if case .bool(false) = object["ok"] {
            if let id = object["id"]?.stringValue,
               id.hasPrefix("ios-chat-history") {
                isLoadingOlderTranscript = false
            }
            if let id = object["id"]?.stringValue,
               id.hasPrefix("ios-sync-chat") {
                _ = finishActiveChatRefresh(requestId: id)
                return
            }
            if let id = object["id"]?.stringValue,
               id.hasPrefix("ios-approval") {
                clearPendingApprovalResponse(requestId: id)
            }
            if let error = object["error"]?.objectValue {
                lastError = userFacingBridgeError(error)
            } else {
                lastError = userFacingBridgeError(["message": object["error"] ?? .string("Bridge request failed.")])
            }
            return
        }

        if let id = object["id"]?.stringValue {
            if id.hasPrefix("ios-projects") {
                handleProjectList(object)
                return
            }
            if id.hasPrefix("ios-create-project") {
                handleProjectCreated(object)
                return
            }
            if id.hasPrefix("ios-models") {
                handleModelList(object)
                return
            }
            if id.hasPrefix("ios-chats") {
                handleChatList(object)
                return
            }
            if id.hasPrefix("ios-status") {
                handleBridgeStatus(object)
                return
            }
            if id.hasPrefix("ios-queue") {
                handlePromptQueueResponse(object)
                return
            }
            if id.hasPrefix("ios-open-chat") {
                handleChatOpened(object)
                return
            }
            if id.hasPrefix("ios-sync-chat") {
                handleChatSynced(object)
                return
            }
            if id.hasPrefix("ios-chat-history") {
                handleChatHistory(object)
                return
            }
            if id.hasPrefix("ios-ping") {
                return
            }
            if id.hasPrefix("ios-approval") {
                if let approvalId = clearPendingApprovalResponse(requestId: id) {
                    approvals.removeAll { $0.id == approvalId }
                }
                appendEvent("approval", "confirmed")
                return
            }
            if id.hasPrefix("ios-subagent") {
                handleSubagentStarted(object)
                return
            }
            if id.hasPrefix("ios-steer") {
                appendEvent("steer", "sent")
                return
            }
            if id.hasPrefix("ios-compact") {
                transcriptStore.addSystemMessage("Context compaction started.")
                publishTranscript()
                return
            }
        }

        if let result = object["result"]?.objectValue,
           let thread = result["thread"]?.objectValue,
           let id = thread["id"]?.stringValue {
            setActiveThread(id)
            return
        }

        appendEvent("response", object["id"]?.description ?? "ok")
    }

    private func handleProjectList(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue else {
            return
        }
        let decodedRoots: [ProjectRootOption] = result["roots"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return ProjectRootOption(json: object)
        } ?? []
        let decodedProjects: [ProjectOption] = result["projects"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return ProjectOption(json: object)
        } ?? []
        projectRoots = decodedRoots
        projects = decodedProjects
        if selectedProjectPath.isEmpty, let first = projects.first {
            selectedProjectPath = first.path
        }
        appendEvent("projects", "\(projects.count)")
    }

    private func handleProjectCreated(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue,
              let projectObject = result["project"]?.objectValue,
              let project = ProjectOption(json: projectObject) else {
            return
        }
        projects.removeAll { $0.path == project.path }
        projects.insert(project, at: 0)
        selectedProjectPath = project.path
        appendEvent("project", "created \(project.path)")
    }

    private func handleModelList(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue else {
            return
        }
        let decoded: [CodexModelOption] = result["data"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return CodexModelOption(json: object)
        } ?? []
        models = decoded.filter { !$0.model.isEmpty }
        if selectedModel.isEmpty {
            selectedModel = models.first(where: \.isDefault)?.model ?? models.first?.model ?? ""
        }
        normalizeReasoningEffortForSelectedModel()
        appendEvent("models", "\(models.count)")
    }

    private func handleChatList(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue else {
            return
        }
        let decoded: [ChatThreadOption] = result["chats"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return ChatThreadOption(json: object)
        } ?? []
        chats = decoded
        appendEvent("chats", "\(decoded.count)")
    }

    private func handlePromptQueueResponse(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue else {
            return
        }
        if let queue = decodePromptQueue(from: result["queue"]) {
            promptQueue = queueForActiveThread(queue)
        } else if let itemObject = result["queueItem"]?.objectValue,
                  let item = PromptQueueItem(json: itemObject) {
            promptQueue.removeAll { $0.id == item.id }
            promptQueue.append(item)
        }
        appendEvent("queue", "\(promptQueue.count)")
    }

    private func handlePromptQueueUpdated(_ object: [String: JSONValue]) {
        promptQueue = queueForActiveThread(decodePromptQueue(from: object["queue"]) ?? [])
        appendEvent("queue", "updated \(promptQueue.count)")
    }

    private func handlePromptQueueStarted(_ object: [String: JSONValue]) {
        guard let item = object["queueItem"]?.objectValue.flatMap(PromptQueueItem.init(json:)) else {
            appendEvent("queue", "started")
            return
        }
        promptQueue.removeAll { $0.id == item.id }
        transcriptStore.addSystemMessage("Queued prompt started: \(item.promptPreview)")
        publishTranscript()
        appendEvent("queue", "started \(item.id)")
    }

    private func handlePromptQueueFailed(_ object: [String: JSONValue]) {
        let message = object["message"]?.stringValue ?? "Queued prompt failed."
        lastError = userFacingBridgeError(["message": .string(message)])
        scheduleNotification(type: "prompt.queue.failed", method: nil, params: ["message": .string(message)], approvalId: nil)
        handlePromptQueueUpdated(object)
    }

    private func decodePromptQueue(from value: JSONValue?) -> [PromptQueueItem]? {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue else {
                return nil
            }
            return PromptQueueItem(json: object)
        }
    }

    private func queueForActiveThread(_ items: [PromptQueueItem]) -> [PromptQueueItem] {
        guard !threadId.isEmpty else {
            return items
        }
        return items.filter { $0.threadId == threadId }
    }

    private func handleBridgeStatus(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue,
              let decoded = BridgeDiagnostics(json: result) else {
            return
        }
        diagnostics = decoded
        appendEvent("diagnostics", "bridge \(decoded.bridgeVersion)")
    }

    private func handleChatOpened(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue,
              let thread = result["thread"]?.objectValue,
              let id = thread["id"]?.stringValue else {
            return
        }

        threadId = id
        if let cwd = result["cwd"]?.stringValue ?? thread["cwd"]?.stringValue {
            selectedProjectPath = cwd
        }
        if let model = result["model"]?.stringValue {
            selectedModel = model
        }
        var entries: [TranscriptEntry] = result["transcript"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return RemoteTranscriptEntry(json: object)?.transcriptEntry
        } ?? []
        transcriptCursor = result["transcriptCursor"]?.stringValue
        hasOlderTranscript = result["hasOlderTranscript"]?.boolValue ?? (transcriptCursor != nil)
        isLoadingOlderTranscript = false
        if let truncation = result["transcriptTruncation"]?.objectValue,
           truncation["truncated"]?.boolValue == true {
            let dropped = Int(truncation["droppedEntries"]?.numberValue ?? 0)
            let returned = Int(truncation["returnedEntryCount"]?.numberValue ?? Double(entries.count))
            entries.insert(
                TranscriptEntry(
                    role: .system,
                    text: "Long desktop history was shortened for mobile. Showing \(returned) recent items; \(dropped) older items were skipped."
                ),
                at: 0
            )
        }
        transcriptStore.replace(with: entries)
        publishTranscript()
        lastActiveChatRefreshAt = Date()
        lastTranscriptSyncAt = Date()
        appendEvent("chat", "opened \(id)")
    }

    private func handleChatSynced(_ object: [String: JSONValue]) {
        let request = finishActiveChatRefresh(requestId: object["id"]?.stringValue)
        let allowsActiveTurnRefresh = request?.allowActiveTurnRefresh == true
        guard (activeTurnId == nil || allowsActiveTurnRefresh),
              let result = object["result"]?.objectValue,
              let thread = result["thread"]?.objectValue,
              let id = thread["id"]?.stringValue,
              id == threadId else {
            return
        }

        let entries: [TranscriptEntry] = result["transcript"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return RemoteTranscriptEntry(json: object)?.transcriptEntry
        } ?? []
        transcriptCursor = result["transcriptCursor"]?.stringValue
        hasOlderTranscript = result["hasOlderTranscript"]?.boolValue ?? (transcriptCursor != nil)
        if allowsActiveTurnRefresh && activeTurnId != nil && !entries.contains(where: \.isStreaming) {
            activeTurnId = nil
            activeTurnLastEventAt = nil
        }
        lastTranscriptSyncAt = Date()
        if transcriptStore.replaceIfChanged(with: entries) {
            publishTranscript()
            appendEvent("chat", "synced \(id)")
        }
    }

    private func handleChatHistory(_ object: [String: JSONValue]) {
        defer {
            isLoadingOlderTranscript = false
        }
        guard let result = object["result"]?.objectValue else {
            hasOlderTranscript = false
            transcriptCursor = nil
            return
        }
        let entries: [TranscriptEntry] = result["transcript"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return RemoteTranscriptEntry(json: object)?.transcriptEntry
        } ?? []
        transcriptCursor = result["transcriptCursor"]?.stringValue
        hasOlderTranscript = result["hasOlderTranscript"]?.boolValue ?? (transcriptCursor != nil)
        if !entries.isEmpty {
            transcriptStore.prepend(entries)
            publishTranscript()
        }
        appendEvent("chat", "loaded \(entries.count) older items")
    }

    private func handleSubagentStarted(_ object: [String: JSONValue]) {
        guard let result = object["result"]?.objectValue,
              let subagent = result["subagent"]?.objectValue,
              let threadId = subagent["threadId"]?.stringValue else {
            return
        }
        let role = subagent["role"]?.stringValue ?? "default"
        transcriptStore.addSystemMessage("Subagent \(role) started: \(shortThreadId(threadId))")
        publishTranscript()
        appendEvent("subagent", "started \(threadId)")
        refreshChats()
    }

    private func handleCodexEvent(_ object: [String: JSONValue]) {
        updateLastEventId(from: object)
        let method = object["method"]?.stringValue ?? "event"
        appendEvent(method, object["params"]?.description ?? "")

        guard let params = object["params"]?.objectValue else {
            return
        }
        scheduleNotification(type: "codex.event", method: method, params: params, approvalId: nil)

        if method == "turn/started",
           let eventThreadId = params["threadId"]?.stringValue,
           let turn = params["turn"]?.objectValue,
           let turnId = turn["id"]?.stringValue {
            if eventThreadId == threadId {
                activeTurnId = turnId
                activeTurnLastEventAt = Date()
                refreshPromptQueue()
            }
        }

        if method == "item/agentMessage/delta",
           let threadId = params["threadId"]?.stringValue,
           let turnId = params["turnId"]?.stringValue,
           let delta = params["delta"]?.stringValue {
            if threadId == self.threadId && turnId == activeTurnId {
                activeTurnLastEventAt = Date()
            }
            transcriptStore.appendAssistantDelta(threadId, turnId: turnId, text: delta)
            publishTranscript()
            return
        }

        if method == "turn/completed" {
            if let threadId = params["threadId"]?.stringValue,
               let turn = params["turn"]?.objectValue,
               let turnId = turn["id"]?.stringValue {
                transcriptStore.finishAssistantTurn(threadId, turnId: turnId)
                publishTranscript()
                if threadId == self.threadId {
                    activeTurnId = nil
                    activeTurnLastEventAt = nil
                    refreshPromptQueue()
                    refreshActiveChatIfNeeded(force: true)
                }
            }
            approvals.removeAll()
            clearPendingApprovalResponses()
        }

        if method == "thread/compacted" {
            transcriptStore.addSystemMessage("Context compacted.")
            publishTranscript()
        }

        if method == "item/completed",
           let item = params["item"]?.objectValue,
           item["type"]?.stringValue == "collabAgentToolCall" {
            transcriptStore.addSystemMessage(collabAgentSummary(item))
            publishTranscript()
        }

        if method == "thread/started",
           let thread = params["thread"]?.objectValue,
           let id = thread["id"]?.stringValue {
            setActiveThread(id)
        }
    }

    private func handleApproval(_ object: [String: JSONValue]) {
        updateLastEventId(from: object)
        guard let approvalId = object["approvalId"]?.stringValue,
              let method = object["method"]?.stringValue else {
            return
        }
        let params = object["params"]?.objectValue ?? [:]
        if approvals.contains(where: { $0.id == approvalId }) {
            return
        }
        approvals.append(ApprovalRequest(id: approvalId, method: method, params: params))
        appendEvent("approval", method)
        scheduleNotification(type: "approval.requested", method: method, params: params, approvalId: approvalId)
    }

    private func handleApprovalResolved(_ object: [String: JSONValue]) {
        updateLastEventId(from: object)
        guard let approvalId = object["approvalId"]?.stringValue else {
            return
        }
        approvals.removeAll { $0.id == approvalId }
        clearPendingApprovalResponses(for: approvalId)
        let decision = object["decision"]?.stringValue ?? "resolved"
        let reason = object["reason"]?.stringValue
        appendEvent("approval", reason == nil ? decision : "\(decision) · \(reason!)")
    }

    @discardableResult
    private func clearPendingApprovalResponse(requestId: String) -> String? {
        guard let approvalId = pendingApprovalResponseIds.removeValue(forKey: requestId) else {
            return nil
        }
        if !pendingApprovalResponseIds.values.contains(approvalId) {
            respondingApprovalIds.remove(approvalId)
        }
        return approvalId
    }

    private func clearPendingApprovalResponses(for approvalId: String) {
        pendingApprovalResponseIds = pendingApprovalResponseIds.filter { $0.value != approvalId }
        respondingApprovalIds.remove(approvalId)
    }

    private func clearPendingApprovalResponses() {
        pendingApprovalResponseIds.removeAll()
        respondingApprovalIds.removeAll()
    }

    private func setActiveThread(_ id: String) {
        if threadId != id {
            threadId = id
            activeTurnId = nil
            activeTurnLastEventAt = nil
            lastTranscriptSyncAt = nil
            promptQueue.removeAll()
            transcriptStore.addSystemMessage("Thread started: \(shortThreadId(id))")
            publishTranscript()
            refreshPromptQueue()
        }
        appendEvent("thread", "started \(id)")
    }

    private func updateLastEventId(from object: [String: JSONValue]) {
        guard let number = object["eventId"]?.numberValue else {
            return
        }
        lastEventId = max(lastEventId, Int(number))
        persistSnapshot()
    }

    private func publishTranscript() {
        transcript = transcriptStore.entries
        persistSnapshot()
    }

    private func appendEvent(_ title: String, _ detail: String) {
        events.insert(BridgeEvent(title: title, detail: detail), at: 0)
        events = Array(events.prefix(100))
    }

    private func scheduleNotification(type: String, method: String?, params: [String: JSONValue], approvalId: String?) {
        guard shouldScheduleMobileNotification(type: type, appIsActive: appIsActive) else {
            return
        }
        guard let intent = mobileNotificationIntent(type: type, method: method, params: params, approvalId: approvalId) else {
            return
        }
        notificationScheduler.schedule(intent)
    }

    private func schedulePendingApprovalNotifications() {
        for approval in approvals where !respondingApprovalIds.contains(approval.id) {
            scheduleNotification(type: "approval.requested", method: approval.method, params: approval.params, approvalId: approval.id)
        }
    }

    private func nextMessageId(prefix: String = "ios") -> String {
        defer { nextId += 1 }
        return "\(prefix)-\(nextId)"
    }

    private func restorePersistedState() {
        guard let snapshot = stateStore.loadSnapshot() else {
            return
        }

        suppressPersistence = true
        selectedProjectPath = snapshot.selectedProjectPath
        selectedModel = snapshot.selectedModel
        selectedReasoningEffort = snapshot.selectedReasoningEffort
        selectedApprovalPolicy = snapshot.selectedApprovalPolicy
        selectedSandbox = snapshot.selectedSandbox
        selectedLanguageCode = AppLanguage(rawValue: snapshot.languageCode)?.rawValue ?? AppLanguage.fallback.rawValue
        autoCompactEnabled = snapshot.autoCompactEnabled
        autoCompactTokenLimit = snapshot.autoCompactTokenLimit
        threadId = snapshot.threadId
        promptDraft = snapshot.promptDraft
        lastEventId = snapshot.lastEventId
        transcriptStore.replace(with: snapshot.transcript)
        transcript = transcriptStore.entries
        transcriptCursor = nil
        hasOlderTranscript = false
        isLoadingOlderTranscript = false
        activeBridgeId = snapshot.activeBridgeId
        savedBridges = stateStore.savedBridges()
        customPromptTemplates = stateStore.customPromptTemplates()
        favoriteProjectPaths = stateStore.favoriteProjectPaths()
        suppressPersistence = false
    }

    private func refreshSavedPairingState() {
        let bridges = stateStore.savedBridges()
        savedBridges = bridges
        let snapshotActiveBridgeId = stateStore.loadSnapshot()?.activeBridgeId ?? ""
        activeBridgeId = snapshotActiveBridgeId.isEmpty ? bridges.first?.id ?? "" : snapshotActiveBridgeId
        hasSavedPairing = !bridges.isEmpty
        savedPairingLabel = bridges.first(where: { $0.id == activeBridgeId })?.label ?? bridges.first?.label
    }

    private func refreshCustomPromptTemplates() {
        customPromptTemplates = stateStore.customPromptTemplates()
    }

    private func refreshFavoriteProjects() {
        favoriteProjectPaths = stateStore.favoriteProjectPaths()
    }

    private func persistSnapshot() {
        guard !suppressPersistence else {
            return
        }
        stateStore.saveSnapshot(
            selectedProjectPath: selectedProjectPath,
            selectedModel: selectedModel,
            selectedReasoningEffort: selectedReasoningEffort,
            selectedApprovalPolicy: selectedApprovalPolicy,
            selectedSandbox: selectedSandbox,
            languageCode: selectedLanguageCode,
            autoCompactEnabled: autoCompactEnabled,
            autoCompactTokenLimit: autoCompactTokenLimit,
            threadId: threadId,
            promptDraft: promptDraft,
            lastEventId: lastEventId,
            transcript: transcriptStore.entries
        )
    }

    private func loadDemoPairingState() {
        suppressPersistence = true
        manuallyDisconnected = false
        pairing = nil
        task = nil
        connectionState = .offline
        events = [
            BridgeEvent(title: "demo", detail: "actual Simulator UI"),
            BridgeEvent(title: "bridge", detail: "ready for QR pairing")
        ]
        projects = []
        projectRoots = []
        models = []
        chats = []
        promptQueue = []
        approvals = []
        respondingApprovalIds = []
        activeTurnId = nil
        activeTurnLastEventAt = nil
        isRefreshingActiveChat = false
        lastTranscriptSyncAt = nil
        selectedProjectPath = ""
        selectedModel = ""
        selectedReasoningEffort = ReasoningEffortOption.fallback
        selectedApprovalPolicy = ApprovalPolicyOption.onRequest.rawValue
        selectedSandbox = SandboxOption.readOnly.rawValue
        selectedLanguageCode = AppLanguage.english.rawValue
        autoCompactEnabled = true
        autoCompactTokenLimit = 120000
        threadId = ""
        promptDraft = ""
        transcriptCursor = nil
        hasOlderTranscript = false
        isLoadingOlderTranscript = false
        diagnostics = nil
        notificationAuthorizationStatus = .authorized
        customPromptTemplates = PromptTemplate.builtIn(language: .english)
        favoriteProjectPaths = ["/Users/malulung/Documents/maludex"]
        let demoPairing = Pairing(
            host: "100.75.40.51",
            port: 8765,
            token: String(repeating: "d", count: 40),
            usesTLS: false,
            label: "Studio Mac"
        )
        let saved = SavedBridge(pairing: demoPairing, now: Date())
        savedBridges = [
            saved,
            SavedBridge(
                pairing: Pairing(
                    host: "100.83.10.24",
                    port: 8765,
                    token: String(repeating: "e", count: 40),
                    usesTLS: false,
                    label: "MacBook Air"
                ),
                now: Date(timeIntervalSinceNow: -3600)
            )
        ]
        activeBridgeId = saved.id
        hasSavedPairing = true
        savedPairingLabel = saved.label
        transcriptStore.replace(with: [])
        transcript = []
    }

    private func loadConnectedDemoState() {
        suppressPersistence = true
        let demoThreadId = "019debd0-b9a1-79b1-97a0-2d47bd12efbd"
        let demoTurnId = "turn-demo-live"
        pairing = Pairing(
            host: "100.75.40.51",
            port: 8765,
            token: String(repeating: "d", count: 40),
            usesTLS: false,
            label: "Studio Mac"
        )
        connectionState = .connected
        selectedProjectPath = "/Users/malulung/Documents/maludex"
        selectedModel = "gpt-5.5"
        selectedReasoningEffort = "high"
        selectedApprovalPolicy = ApprovalPolicyOption.onRequest.rawValue
        selectedSandbox = SandboxOption.workspaceWrite.rawValue
        threadId = demoThreadId
        activeTurnId = demoTurnId
        activeTurnLastEventAt = Date()
        isRefreshingActiveChat = false
        lastTranscriptSyncAt = Date(timeIntervalSinceNow: -45)
        promptDraft = "Ask maludex to keep the iPhone transcript in sync..."
        projectRoots = [
            ProjectRootOption(path: "/Users/malulung/Documents", name: "Documents"),
            ProjectRootOption(path: "/Users/malulung/Developer", name: "Developer")
        ]
        projects = [
            ProjectOption(path: "/Users/malulung/Documents/maludex", name: "maludex", source: "recent", updatedAt: Date().timeIntervalSince1970),
            ProjectOption(path: "/Users/malulung/Documents/New project", name: "New project", source: "scan", updatedAt: Date().timeIntervalSince1970 - 7200)
        ]
        models = [
            CodexModelOption(
                model: "gpt-5.5",
                displayName: "GPT-5.5",
                detail: "Frontier model",
                inputModalities: ["text", "image"],
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium",
                isDefault: true
            ),
            CodexModelOption(
                model: "gpt-5.4-mini",
                displayName: "GPT-5.4 Mini",
                detail: "Fast coding model",
                inputModalities: ["text", "image"],
                supportedReasoningEfforts: ["low", "medium", "high"],
                defaultReasoningEffort: "medium"
            )
        ]
        chats = [
            ChatThreadOption(json: [
                "id": .string(demoThreadId),
                "title": .string("maludex live sync"),
                "preview": .string("Desktop updates now refresh automatically on iPhone."),
                "cwd": .string(selectedProjectPath),
                "updatedAt": .number(Date().timeIntervalSince1970)
            ])!,
            ChatThreadOption(json: [
                "id": .string("019debd0-b9a1-79b1-97a0-history"),
                "title": .string("Release notes"),
                "preview": .string("Prepare the v0.7.x release summary."),
                "cwd": .string(selectedProjectPath),
                "updatedAt": .number(Date().timeIntervalSince1970 - 5000)
            ])!
        ]
        promptQueue = [
            PromptQueueItem(json: [
                "id": .string("queue-demo-1"),
                "threadId": .string(demoThreadId),
                "promptPreview": .string("Regenerate README media from the real simulator"),
                "promptBytes": .number(58),
                "attachmentCount": .number(0),
                "createdAt": .string("2026-05-05T00:00:00Z")
            ])!,
            PromptQueueItem(json: [
                "id": .string("queue-demo-2"),
                "threadId": .string(demoThreadId),
                "promptPreview": .string("Summarize the security defaults"),
                "promptBytes": .number(39),
                "attachmentCount": .number(1),
                "createdAt": .string("2026-05-05T00:01:00Z")
            ])!
        ]
        approvals = []
        diagnostics = BridgeDiagnostics(json: [
            "bridgeVersion": .string("0.7.5"),
            "protocolVersion": .number(1),
            "minClientProtocolVersion": .number(1),
            "host": .string("100.75.40.51"),
            "port": .number(8765),
            "usesTLS": .bool(false),
            "tokenFileValid": .bool(true),
            "codexRunning": .bool(true),
            "connectedClient": .bool(true),
            "eventBufferSize": .number(42),
            "eventReplayLimit": .number(500),
            "activeTurnCount": .number(1),
            "promptQueueCount": .number(2),
            "pendingApprovalCount": .number(0),
            "mobileHandoffMaxEntries": .number(200),
            "projectRootCount": .number(2),
            "resumedThreadCount": .number(4),
            "uptimeSeconds": .number(738),
            "activeTurns": .array([
                .object([
                    "threadId": .string(demoThreadId),
                    "turnId": .string(demoTurnId)
                ])
            ]),
            "pendingApprovals": .array([])
        ])
        transcriptStore.replace(with: [
            TranscriptEntry(
                role: .system,
                text: "Actual Simulator demo mode: this is the real maludex chat UI running in Xcode's iOS Simulator.",
                threadId: demoThreadId,
                createdAt: Date(timeIntervalSinceNow: -180)
            ),
            TranscriptEntry(
                role: .user,
                text: "The GitHub demo looked fake. Replace it with a real Xcode Simulator recording.",
                attachments: [
                    TranscriptAttachment(
                        kind: .image,
                        filename: "simulator-request.png",
                        mimeType: "image/png",
                        byteCount: 1827132
                    )
                ],
                threadId: demoThreadId,
                turnId: demoTurnId,
                createdAt: Date(timeIntervalSinceNow: -120)
            ),
            TranscriptEntry(
                role: .assistant,
                text: "Agreed. I am building the app, launching it in Simulator, and recording the real SwiftUI interface with simctl.",
                isStreaming: true,
                threadId: demoThreadId,
                turnId: demoTurnId,
                createdAt: Date(timeIntervalSinceNow: -80)
            )
        ])
        transcript = transcriptStore.entries
        events.insert(BridgeEvent(title: "bridge.ready", detail: "demo UI connected"), at: 0)
    }

    private func startDemoPlayback() {
        demoPlaybackTask?.cancel()
        demoPlaybackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard let self, self.isDemoMode else { return }
            self.loadConnectedDemoState()

            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled, self.isDemoMode else { return }
            self.transcriptStore.appendAssistantDelta(
                self.threadId,
                turnId: "turn-demo-live",
                text: "\n\nThe iPhone transcript also performs periodic desktop history catch-up, so stale desktop updates appear without reopening the chat."
            )
            self.publishTranscript()

            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled, self.isDemoMode else { return }
            self.approvals = [
                ApprovalRequest(
                    id: "approval-demo-1",
                    method: "item/commandExecution/requestApproval",
                    params: [
                        "command": .string("./scripts/create-demo-video.sh"),
                        "cwd": .string(self.selectedProjectPath)
                    ]
                )
            ]
            self.diagnostics = BridgeDiagnostics(json: [
                "bridgeVersion": .string("0.7.5"),
                "protocolVersion": .number(1),
                "minClientProtocolVersion": .number(1),
                "host": .string("100.75.40.51"),
                "port": .number(8765),
                "usesTLS": .bool(false),
                "tokenFileValid": .bool(true),
                "codexRunning": .bool(true),
                "connectedClient": .bool(true),
                "eventBufferSize": .number(48),
                "eventReplayLimit": .number(500),
                "activeTurnCount": .number(1),
                "promptQueueCount": .number(2),
                "pendingApprovalCount": .number(1),
                "mobileHandoffMaxEntries": .number(200),
                "projectRootCount": .number(2),
                "resumedThreadCount": .number(4),
                "uptimeSeconds": .number(760),
                "activeTurns": .array([
                    .object([
                        "threadId": .string(self.threadId),
                        "turnId": .string("turn-demo-live")
                    ])
                ]),
                "pendingApprovals": .array([
                    .object([
                        "approvalId": .string("approval-demo-1"),
                        "method": .string("item/commandExecution/requestApproval")
                    ])
                ])
            ])
            self.events.insert(BridgeEvent(title: "approval.requested", detail: "create real simulator demo"), at: 0)

            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, self.isDemoMode else { return }
            self.approvals.removeAll()
            self.activeTurnId = nil
            self.activeTurnLastEventAt = nil
            self.transcriptStore.finishAssistantTurn(self.threadId, turnId: "turn-demo-live")
            self.transcriptStore.addSystemMessage("Approved command: real Simulator capture completed.")
            self.transcriptStore.appendAssistantDelta(
                self.threadId,
                turnId: "turn-demo-final",
                text: "The README media now comes from the installed app running in iOS Simulator, not from handcrafted PNG frames."
            )
            self.transcriptStore.finishAssistantTurn(self.threadId, turnId: "turn-demo-final")
            self.lastTranscriptSyncAt = Date()
            self.publishTranscript()
            self.promptDraft = "Ask maludex to publish the real simulator demo..."
            self.events.insert(BridgeEvent(title: "turn/completed", detail: "simulator media ready"), at: 0)

            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, self.isDemoMode else { return }
            self.promptQueue = [
                PromptQueueItem(json: [
                    "id": .string("queue-demo-3"),
                    "threadId": .string(self.threadId),
                    "promptPreview": .string("Open the PR and verify CI"),
                    "promptBytes": .number(27),
                    "attachmentCount": .number(0),
                    "createdAt": .string("2026-05-05T00:02:00Z")
                ])!
            ]
            self.events.insert(BridgeEvent(title: "prompt.queue.updated", detail: "1 queued"), at: 0)
        }
    }
}

private final class LocalNotificationScheduler {
    private let center = UNUserNotificationCenter.current()
    private var requestedAuthorization = false

    func requestAuthorizationIfNeeded(completion: (() -> Void)? = nil) {
        guard !requestedAuthorization else {
            completion?()
            return
        }
        requestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            completion?()
        }
    }

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    func schedule(_ intent: MobileNotificationIntent) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = intent.title
        content.body = intent.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: intent.identifier, content: content, trigger: nil))
    }
}

private func shortThreadId(_ threadId: String) -> String {
    if threadId.count <= 12 {
        return threadId
    }
    return "\(threadId.prefix(8))...\(threadId.suffix(4))"
}

private func validReasoningEffort(_ value: String) -> String {
    if ReasoningEffortOption.allCases.map(\.rawValue).contains(value) {
        return value
    }
    return ReasoningEffortOption.fallback
}

private func validApprovalPolicy(_ value: String) -> String {
    if ApprovalPolicyOption.allCases.map(\.rawValue).contains(value) {
        return value
    }
    return ApprovalPolicyOption.onRequest.rawValue
}

private func validSandbox(_ value: String) -> String {
    if SandboxOption.allCases.map(\.rawValue).contains(value) {
        return value
    }
    return SandboxOption.readOnly.rawValue
}

private func collabAgentSummary(_ item: [String: JSONValue]) -> String {
    let tool = item["tool"]?.stringValue ?? "subagent"
    let status = item["status"]?.stringValue ?? "updated"
    let receivers = item["receiverThreadIds"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? ""
    if receivers.isEmpty {
        return "Subagent \(tool): \(status)"
    }
    return "Subagent \(tool): \(status) (\(receivers))"
}
