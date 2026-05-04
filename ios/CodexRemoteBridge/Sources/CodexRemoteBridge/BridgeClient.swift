import Foundation

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
    @Published private(set) var projects: [ProjectOption] = []
    @Published private(set) var projectRoots: [ProjectRootOption] = []
    @Published private(set) var models: [CodexModelOption] = []
    @Published private(set) var chats: [ChatThreadOption] = []
    @Published private(set) var isLoadingOlderTranscript = false
    @Published private(set) var hasOlderTranscript = false
    @Published private(set) var hasSavedPairing = false
    @Published private(set) var savedPairingLabel: String?
    @Published private(set) var savedBridges: [SavedBridge] = []
    @Published private(set) var activeBridgeId = ""
    @Published private(set) var diagnostics: BridgeDiagnostics?
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
    @Published var autoCompactEnabled = true {
        didSet { persistSnapshot() }
    }
    @Published var autoCompactTokenLimit = 120000 {
        didSet { persistSnapshot() }
    }
    @Published var threadId = "" {
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
    private let transcriptStore = TranscriptStore()
    private let stateStore: DeviceStateStore
    private var suppressPersistence = false

    init(stateStore: DeviceStateStore = DeviceStateStore()) {
        self.stateStore = stateStore
        restorePersistedState()
        refreshSavedPairingState()
    }

    func connect(pairing: Pairing) {
        manuallyDisconnected = false
        cancelReconnect()
        closeSocket(setOffline: true)
        self.pairing = pairing
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
            sendPing()
            return
        }
        if connectionState == .offline || connectionState == .failed {
            connectSavedPairingIfAvailable()
        }
    }

    func connectSavedBridge(id: String) {
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

    func disconnect() {
        manuallyDisconnected = true
        cancelReconnect()
        closeSocket(setOffline: true)
        connectionState = .offline
        approvals.removeAll()
    }

    func forgetSavedDeviceState() {
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
        autoCompactEnabled = true
        autoCompactTokenLimit = 120000
        threadId = ""
        lastEventId = 0
        transcriptCursor = nil
        hasOlderTranscript = false
        isLoadingOlderTranscript = false
        projects.removeAll()
        projectRoots.removeAll()
        models.removeAll()
        chats.removeAll()
        transcriptStore.replace(with: [])
        transcript = []
        savedBridges = []
        activeBridgeId = ""
        hasSavedPairing = false
        savedPairingLabel = nil
        suppressPersistence = false
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

    func approve(_ approval: ApprovalRequest) {
        respond(to: approval, decision: "accept")
    }

    func deny(_ approval: ApprovalRequest) {
        respond(to: approval, decision: "decline")
    }

    private func respond(to approval: ApprovalRequest, decision: String) {
        var body: [String: JSONValue] = [
            "id": .string(nextMessageId()),
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

        send(body)
        approvals.removeAll { $0.id == approval.id }
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
        isLoadingOlderTranscript = false
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
                    self?.sendPing()
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func sendPing() {
        guard connectionState == .connected else {
            return
        }
        send([
            "id": .string(nextMessageId(prefix: "ios-ping")),
            "type": .string("ping")
        ], reportErrors: false)
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
                appendEvent("bridge", "ready \(version)")
                refreshProjects()
                refreshModels()
                refreshChats()
            case "response":
                handleResponse(object)
            case "codex.event":
                handleCodexEvent(object)
            case "approval.requested":
                handleApproval(object)
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
            if id.hasPrefix("ios-open-chat") {
                handleChatOpened(object)
                return
            }
            if id.hasPrefix("ios-chat-history") {
                handleChatHistory(object)
                return
            }
            if id.hasPrefix("ios-ping") {
                return
            }
            if id.hasPrefix("ios-subagent") {
                handleSubagentStarted(object)
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
        appendEvent("chat", "opened \(id)")
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

        if method == "item/agentMessage/delta",
           let threadId = params["threadId"]?.stringValue,
           let turnId = params["turnId"]?.stringValue,
           let delta = params["delta"]?.stringValue {
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
            }
            approvals.removeAll()
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
    }

    private func setActiveThread(_ id: String) {
        if threadId != id {
            threadId = id
            transcriptStore.addSystemMessage("Thread started: \(shortThreadId(id))")
            publishTranscript()
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
        autoCompactEnabled = snapshot.autoCompactEnabled
        autoCompactTokenLimit = snapshot.autoCompactTokenLimit
        threadId = snapshot.threadId
        lastEventId = snapshot.lastEventId
        transcriptStore.replace(with: snapshot.transcript)
        transcript = transcriptStore.entries
        transcriptCursor = nil
        hasOlderTranscript = false
        isLoadingOlderTranscript = false
        activeBridgeId = snapshot.activeBridgeId
        savedBridges = stateStore.savedBridges()
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
            autoCompactEnabled: autoCompactEnabled,
            autoCompactTokenLimit: autoCompactTokenLimit,
            threadId: threadId,
            lastEventId: lastEventId,
            transcript: transcriptStore.entries
        )
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
