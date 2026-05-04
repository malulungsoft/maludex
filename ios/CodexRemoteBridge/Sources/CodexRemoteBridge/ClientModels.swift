import Foundation

struct ProjectOption: Identifiable, Equatable {
    let path: String
    let name: String
    let source: String
    let updatedAt: Double?

    var id: String { path }

    init(path: String, name: String, source: String, updatedAt: Double? = nil) {
        self.path = path
        self.name = name
        self.source = source
        self.updatedAt = updatedAt
    }

    init?(json: [String: JSONValue]) {
        guard let path = json["path"]?.stringValue,
              let name = json["name"]?.stringValue else {
            return nil
        }
        self.path = path
        self.name = name
        self.source = json["source"]?.stringValue ?? "scan"
        self.updatedAt = json["updatedAt"]?.numberValue
    }
}

struct ProjectRootOption: Identifiable, Equatable {
    let path: String
    let name: String

    var id: String { path }

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    init?(json: [String: JSONValue]) {
        guard let path = json["path"]?.stringValue else {
            return nil
        }
        self.path = path
        self.name = json["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent
    }
}

struct PromptQueueItem: Identifiable, Equatable {
    let id: String
    let threadId: String
    let promptPreview: String
    let promptBytes: Int
    let attachmentCount: Int
    let createdAt: Date?

    init?(json: [String: JSONValue]) {
        guard let id = json["id"]?.stringValue,
              let threadId = json["threadId"]?.stringValue else {
            return nil
        }
        self.id = id
        self.threadId = threadId
        self.promptPreview = json["promptPreview"]?.stringValue ?? "Queued prompt"
        self.promptBytes = Int(json["promptBytes"]?.numberValue ?? 0)
        self.attachmentCount = Int(json["attachmentCount"]?.numberValue ?? 0)
        if let createdAtText = json["createdAt"]?.stringValue {
            self.createdAt = ISO8601DateFormatter().date(from: createdAtText)
        } else {
            self.createdAt = nil
        }
    }
}

struct CodexModelOption: Identifiable, Equatable {
    let model: String
    let displayName: String
    let detail: String
    let inputModalities: [String]
    let supportedReasoningEfforts: [String]
    let defaultReasoningEffort: String?
    let isDefault: Bool

    var id: String { model }

    var supportsImages: Bool {
        inputModalities.contains("image")
    }

    init(
        model: String,
        displayName: String,
        detail: String = "",
        inputModalities: [String] = ["text"],
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil,
        isDefault: Bool = false
    ) {
        self.model = model
        self.displayName = displayName
        self.detail = detail
        self.inputModalities = inputModalities
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.isDefault = isDefault
    }

    init?(json: [String: JSONValue]) {
        guard let model = json["model"]?.stringValue ?? json["id"]?.stringValue else {
            return nil
        }
        self.model = model
        self.displayName = json["displayName"]?.stringValue ?? model
        self.detail = json["description"]?.stringValue ?? ""
        self.inputModalities = json["inputModalities"]?.arrayValue?.compactMap(\.stringValue) ?? ["text"]
        self.supportedReasoningEfforts = json["supportedReasoningEfforts"]?.arrayValue?.compactMap { value in
            if let raw = value.stringValue {
                return raw
            }
            if let object = value.objectValue {
                return object["reasoningEffort"]?.stringValue ?? object["value"]?.stringValue ?? object["id"]?.stringValue
            }
            return nil
        } ?? []
        self.defaultReasoningEffort = json["defaultReasoningEffort"]?.stringValue
        self.isDefault = json["isDefault"]?.boolValue ?? false
    }
}

enum ReasoningEffortOption: String, CaseIterable, Identifiable, Codable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "X High"
        }
    }

    var subtitle: String {
        switch self {
        case .minimal:
            return "fastest"
        case .low:
            return "light"
        case .medium:
            return "balanced"
        case .high:
            return "deep"
        case .xhigh:
            return "max"
        }
    }

    static let fallback = "medium"
}

enum ApprovalPolicyOption: String, CaseIterable, Identifiable, Codable {
    case onRequest = "on-request"
    case onFailure = "on-failure"
    case untrusted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onRequest:
            return "On request"
        case .onFailure:
            return "On failure"
        case .untrusted:
            return "Untrusted"
        }
    }

    var detail: String {
        switch self {
        case .onRequest:
            return "ask before risky actions"
        case .onFailure:
            return "ask after sandbox failure"
        case .untrusted:
            return "ask more often"
        }
    }
}

enum SandboxOption: String, CaseIterable, Identifiable, Codable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly:
            return "Read only"
        case .workspaceWrite:
            return "Workspace write"
        }
    }

    var detail: String {
        switch self {
        case .readOnly:
            return "no file writes by default"
        case .workspaceWrite:
            return "writes only inside project"
        }
    }
}

enum SubagentRoleOption: String, CaseIterable, Identifiable {
    case `default`
    case explorer
    case worker
    case reviewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default:
            return "Default"
        case .explorer:
            return "Explorer"
        case .worker:
            return "Worker"
        case .reviewer:
            return "Reviewer"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case korean = "ko"

    static let fallback = AppLanguage.english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english:
            return "English"
        case .korean:
            return "한국어"
        }
    }
}

struct AppCopy: Equatable {
    let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    init(languageCode: String) {
        self.language = AppLanguage(rawValue: languageCode) ?? .fallback
    }

    var okButton: String { text("OK", "확인") }
    var closeButton: String { text("Close", "닫기") }
    var cancelButton: String { text("Cancel", "취소") }
    var doneButton: String { text("Done", "완료") }
    var startButton: String { text("Start", "시작") }
    var createButton: String { text("Create", "생성") }
    var refreshButton: String { text("Refresh", "새로고침") }
    var connectButton: String { text("Connect", "연결") }
    var scanButton: String { text("Scan", "스캔") }
    var settingsTitle: String { text("Settings", "설정") }
    var sessionTitle: String { text("Session", "세션") }
    var languageLabel: String { text("Language", "언어") }
    var showControlsTitle: String { text("Show controls", "컨트롤 보기") }
    var hideControlsTitle: String { text("Hide controls", "컨트롤 숨기기") }
    var pairingPayloadTitle: String { text("Pairing payload", "페어링 코드") }
    var maludexBridgeTitle: String { text("maludex bridge", "maludex 브릿지") }
    var chatsTitle: String { text("Chats", "채팅") }
    var bridgesTitle: String { text("Bridges", "브릿지") }
    var diagnosticsTitle: String { text("Diagnostics", "진단") }
    var subagentTitle: String { text("Subagent", "서브에이전트") }
    var roleTitle: String { text("Role", "역할") }
    var disconnectTitle: String { text("Disconnect", "연결 끊기") }
    var activeBridgeTitle: String { text("Active bridge", "활성 브릿지") }
    var activeThreadTitle: String { text("Active thread", "활성 스레드") }
    var noActiveThread: String { text("No active thread", "활성 스레드 없음") }
    var noBridge: String { text("No bridge", "브릿지 없음") }
    var projectTitle: String { text("Project", "프로젝트") }
    var noProjectsTitle: String { text("No projects", "프로젝트 없음") }
    var refreshProjectsTitle: String { text("Refresh projects", "프로젝트 새로고침") }
    var newProjectTitle: String { text("New project", "새 프로젝트") }
    var projectNamePlaceholder: String { text("Project name", "프로젝트 이름") }
    var locationTitle: String { text("Location", "위치") }
    var selectProjectPrompt: String { text("Select a project", "프로젝트를 선택하세요") }
    var modelTitle: String { text("Model", "모델") }
    var defaultModelTitle: String { text("Default", "기본값") }
    var refreshModelsTitle: String { text("Refresh models", "모델 새로고침") }
    var supportsImagesTitle: String { text("Supports images", "이미지 지원") }
    var startThreadTitle: String { text("Start thread", "스레드 시작") }
    var intelligenceTitle: String { text("Intelligence", "인텔리전스") }
    var autoCompactTitle: String { text("Auto compact", "자동 컨텍스트 압축") }
    var compactNowTitle: String { text("Compact now", "지금 압축") }
    var permissionsTitle: String { text("Permissions", "권한") }
    var filesTitle: String { text("Files", "파일") }
    var approvalsTitle: String { text("Approvals", "승인") }
    var mobileSecurityNote: String { text("Full access and never-approve are unavailable on mobile.", "모바일에서는 전체 접근과 무승인 모드를 사용할 수 없습니다.") }
    var conversationTitle: String { text("Conversation", "대화") }
    var noTranscriptTitle: String { text("No transcript yet", "아직 대화가 없습니다") }
    var noTranscriptSubtitle: String { text("Ready for a new turn.", "새 작업을 시작할 준비가 됐습니다.") }
    var streamingTitle: String { text("Streaming", "응답 중") }
    var copyTitle: String { text("Copy", "복사") }
    var copyTextTitle: String { text("Copy text", "텍스트 복사") }
    var collapseTitle: String { text("Collapse", "접기") }
    var expandTitle: String { text("Expand", "펼치기") }
    var collapseMessageTitle: String { text("Collapse message", "메시지 접기") }
    var expandMessageTitle: String { text("Expand message", "메시지 펼치기") }
    var youLabel: String { text("You", "나") }
    var threadLabel: String { text("Thread", "스레드") }
    var pendingTitle: String { text("Pending", "대기 중") }
    var approvalRespondingTitle: String { text("Waiting for bridge", "브릿지 확인 대기") }
    var approvalRespondingDetail: String { text("Your response was sent. Keep this card open until the Mac bridge confirms it.", "응답을 보냈습니다. Mac 브릿지가 확인할 때까지 이 카드를 유지합니다.") }
    var approveTitle: String { text("Approve", "승인") }
    var denyTitle: String { text("Deny", "거부") }
    var queueTitle: String { text("Queue", "대기열") }
    var queuedPromptTitle: String { text("Queued prompt", "대기 중인 프롬프트") }
    var moveQueuedPromptUpTitle: String { text("Move queued prompt up", "프롬프트 순서 올리기") }
    var moveQueuedPromptDownTitle: String { text("Move queued prompt down", "프롬프트 순서 내리기") }
    var cancelQueuedPromptTitle: String { text("Cancel queued prompt", "대기 프롬프트 취소") }
    var attachmentsTitle: String { text("attachments", "첨부") }
    var stopTitle: String { text("Stop", "중지") }
    var photoTitle: String { text("Photo", "사진") }
    var fileTitle: String { text("File", "파일") }
    var voiceInputTitle: String { text("Voice input", "음성 입력") }
    var stopVoiceInputTitle: String { text("Stop voice input", "음성 입력 중지") }
    var steerActiveTurnTitle: String { text("Steer active turn", "현재 작업에 추가 지시") }
    var sendTitle: String { text("Send", "보내기") }
    var removeAttachmentTitle: String { text("Remove attachment", "첨부 제거") }
    var savedBridgesTitle: String { text("Saved bridges", "저장된 브릿지") }
    var savedBridgesSubtitle: String { text("Switch between paired local PCs.", "페어링된 로컬 PC들을 전환합니다.") }
    var forgetTitle: String { text("Forget", "삭제") }
    var forgetAllTitle: String { text("Forget all", "모두 삭제") }
    var pairAnotherPCSubtitle: String { text("Pair another PC by scanning that PC's maludex QR.", "다른 PC의 maludex QR을 스캔해서 추가로 페어링하세요.") }
    var diagnosticsConnectionTitle: String { text("Connection", "연결") }
    var appVersionTitle: String { text("App version", "앱 버전") }
    var stateTitle: String { text("State", "상태") }
    var bridgeTitle: String { text("Bridge", "브릿지") }
    var bridgeVersionTitle: String { text("Bridge version", "브릿지 버전") }
    var endpointTitle: String { text("Endpoint", "엔드포인트") }
    var protocolTitle: String { text("Protocol", "프로토콜") }
    var tokenFileTitle: String { text("Token file", "토큰 파일") }
    var codexTitle: String { text("Codex", "Codex") }
    var runtimeTitle: String { text("Runtime", "런타임") }
    var connectedClientTitle: String { text("Connected client", "연결된 클라이언트") }
    var activeTurnsTitle: String { text("Active turns", "진행 중 작업") }
    var pendingApprovalsTitle: String { text("Pending approvals", "대기 중 승인") }
    var eventBufferTitle: String { text("Event buffer", "이벤트 버퍼") }
    var projectRootsTitle: String { text("Project roots", "프로젝트 루트") }
    var uptimeTitle: String { text("Uptime", "가동 시간") }
    var reportTitle: String { text("Report", "리포트") }
    var copyReportTitle: String { text("Copy report", "리포트 복사") }
    var noDiagnosticsTitle: String { text("No diagnostics loaded yet.", "아직 진단 정보를 불러오지 않았습니다.") }
    var recoveryTitle: String { text("Recovery", "복구") }
    var cannotConnectTitle: String { text("Cannot connect", "연결할 수 없음") }
    var cannotConnectDetail: String { text("Check that the Mac bridge is running and the iPhone can reach the paired Tailscale or Nginx address.", "Mac 브릿지가 실행 중이고 iPhone에서 페어링된 Tailscale 또는 Nginx 주소에 접근 가능한지 확인하세요.") }
    var authFailedTitle: String { text("Authentication failed", "인증 실패") }
    var authFailedDetail: String { text("The token may have rotated. Forget this bridge on iPhone and scan the new QR.", "토큰이 변경됐을 수 있습니다. iPhone에서 이 브릿지를 삭제한 뒤 새 QR을 스캔하세요.") }
    var codexNotRunningTitle: String { text("Codex not running", "Codex가 실행 중이 아님") }
    var codexNotRunningDetail: String { text("Open the Mac and confirm Codex is installed and logged in.", "Mac에서 Codex가 설치되어 있고 로그인되어 있는지 확인하세요.") }

    func askPlaceholder(brand: String) -> String {
        text("Ask \(brand)...", "\(brand)에게 요청하기...")
    }

    func limitTitle(thousands: Int) -> String {
        text("Limit \(thousands)k", "제한 \(thousands)k")
    }

    func connectionState(_ value: String) -> String {
        switch value {
        case "Offline":
            return text("Offline", "오프라인")
        case "Connecting":
            return text("Connecting", "연결 중")
        case "Connected":
            return text("Connected", "연결됨")
        case "Connection issue":
            return text("Connection issue", "연결 문제")
        default:
            return value
        }
    }

    func reasoningTitle(_ value: String) -> String {
        switch value {
        case "minimal":
            return text("Minimal", "최소")
        case "low":
            return text("Low", "낮음")
        case "medium":
            return text("Medium", "중간")
        case "high":
            return text("High", "높음")
        case "xhigh":
            return text("X High", "매우 높음")
        default:
            return value
        }
    }

    func sandboxTitle(_ value: String) -> String {
        switch value {
        case SandboxOption.readOnly.rawValue:
            return text("Read only", "읽기 전용")
        case SandboxOption.workspaceWrite.rawValue:
            return text("Workspace write", "워크스페이스 쓰기")
        default:
            return value
        }
    }

    func approvalPolicyTitle(_ value: String) -> String {
        switch value {
        case ApprovalPolicyOption.onRequest.rawValue:
            return text("On request", "요청 시 승인")
        case ApprovalPolicyOption.onFailure.rawValue:
            return text("On failure", "실패 시 승인")
        case ApprovalPolicyOption.untrusted.rawValue:
            return text("Untrusted", "신뢰 낮음")
        default:
            return value
        }
    }

    private func text(_ english: String, _ korean: String) -> String {
        language == .korean ? korean : english
    }
}

func preferredSpeechLocaleIdentifier(
    preferredLanguages: [String] = Locale.preferredLanguages,
    availableLocaleIdentifiers: Set<String>
) -> String {
    if availableLocaleIdentifiers.contains("ko-KR") {
        return "ko-KR"
    }

    for language in preferredLanguages {
        let normalized = normalizedLocaleIdentifier(language)
        if availableLocaleIdentifiers.contains(normalized) {
            return normalized
        }

        let languageCode = normalized.split(separator: "-").first.map(String.init) ?? normalized
        if languageCode == "ko", availableLocaleIdentifiers.contains("ko-KR") {
            return "ko-KR"
        }
        if let match = availableLocaleIdentifiers.sorted().first(where: { $0 == languageCode || $0.hasPrefix("\(languageCode)-") }) {
            return match
        }
    }

    if availableLocaleIdentifiers.contains("ko-KR") {
        return "ko-KR"
    }
    if availableLocaleIdentifiers.contains("en-US") {
        return "en-US"
    }
    return availableLocaleIdentifiers.sorted().first ?? "en-US"
}

private func normalizedLocaleIdentifier(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: "-")
}

let mobileProtocolVersion = 1
let minimumSupportedBridgeProtocolVersion = 1
let maludexClientVersion = "0.6.11"

func bridgeCompatibilityWarning(readyMessage: [String: JSONValue]) -> String? {
    let bridgeProtocol = Int(readyMessage["protocolVersion"]?.numberValue ?? 0)
    let minimumClientProtocol = Int(readyMessage["minClientProtocolVersion"]?.numberValue ?? 1)
    let bridgeVersion = readyMessage["bridgeVersion"]?.stringValue ?? "unknown"

    if minimumClientProtocol > mobileProtocolVersion {
        return "Update maludex iPhone app. This bridge requires mobile protocol \(minimumClientProtocol), but this app supports \(mobileProtocolVersion). Bridge version: \(bridgeVersion)."
    }

    if bridgeProtocol < minimumSupportedBridgeProtocolVersion {
        return "Update maludex bridge. This app expects bridge protocol \(minimumSupportedBridgeProtocolVersion) or newer, but the bridge reported \(bridgeProtocol). Bridge version: \(bridgeVersion)."
    }

    return nil
}

func userFacingBridgeError(_ error: [String: JSONValue]) -> String {
    let code = error["code"]?.stringValue ?? ""
    let message = error["message"]?.stringValue ?? error.description
    let normalized = message.lowercased()

    if code == "auth_failed" || normalized.contains("unauthorized") || normalized.contains("401") {
        return "Bridge authentication failed. Please pair again from the Mac bridge QR code, or rotate the token if the QR was exposed."
    }

    if normalized.contains("no active turn is tracked") {
        return "No active Codex turn is running for this chat. The stop request was ignored."
    }

    if normalized.contains("start a thread") {
        return "Start or open a chat before sending a prompt."
    }

    if normalized.contains("larger than 15 mb") {
        return "Attachment is larger than 15 MB. Choose a smaller file."
    }

    if normalized.contains("not connected") || normalized.contains("still connecting") {
        return userFacingConnectionError(message)
    }

    return message
}

func userFacingConnectionError(_ message: String) -> String {
    let normalized = message.lowercased()

    if normalized.contains("offline")
        || normalized.contains("could not connect")
        || normalized.contains("cannot connect")
        || normalized.contains("network connection was lost")
        || normalized.contains("timed out")
        || normalized.contains("not connected")
        || normalized.contains("still connecting") {
        return "Cannot reach the Mac bridge. Check that maludex bridge is running, the iPhone is on the same Tailscale/Nginx route, and the pairing address is correct."
    }

    return message
}

func normalizedReconnectEventId(current: Int, serverLastEventId: Int) -> Int {
    serverLastEventId < current ? max(0, serverLastEventId) : current
}

struct MobileNotificationIntent: Equatable {
    let identifier: String
    let title: String
    let body: String
}

func mobileNotificationIntent(
    type: String,
    method: String?,
    params: [String: JSONValue],
    approvalId: String?
) -> MobileNotificationIntent? {
    switch type {
    case "approval.requested":
        let id = approvalId ?? "approval"
        return MobileNotificationIntent(
            identifier: "approval-\(id)",
            title: "Approval needed",
            body: "\(approvalTitle(for: method)) is waiting on your iPhone."
        )
    case "codex.event":
        guard method == "turn/completed" else {
            return nil
        }
        let thread = params["threadId"]?.stringValue.map(shortThreadLabel) ?? "current chat"
        return MobileNotificationIntent(
            identifier: "turn-completed-\(thread)-\(Int(Date().timeIntervalSince1970))",
            title: "Turn finished",
            body: "maludex finished a turn in \(thread)."
        )
    case "prompt.queue.failed":
        return MobileNotificationIntent(
            identifier: "queue-failed-\(Int(Date().timeIntervalSince1970))",
            title: "Queued prompt failed",
            body: params["message"]?.stringValue ?? "A queued prompt could not be started."
        )
    default:
        return nil
    }
}

func shouldScheduleMobileNotification(type: String, appIsActive: Bool) -> Bool {
    if type == "approval.requested" {
        return !appIsActive
    }
    return true
}

private func approvalTitle(for method: String?) -> String {
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

private func shortThreadLabel(_ threadId: String) -> String {
    threadId.count <= 8 ? threadId : String(threadId.prefix(8))
}

func messageRelativeTime(from date: Date, now: Date = Date()) -> String {
    let elapsed = max(0, Int(now.timeIntervalSince(date)))
    if elapsed < 60 {
        return "방금 전"
    }

    let minutes = elapsed / 60
    if minutes < 60 {
        return "\(minutes)분 전"
    }

    let hours = minutes / 60
    if hours < 24 {
        return "\(hours)시간 전"
    }

    let days = hours / 24
    if days < 30 {
        return "\(days)일 전"
    }

    let months = days / 30
    if months < 12 {
        return "\(months)개월 전"
    }

    return "\(months / 12)년 전"
}

struct BridgeDiagnostics: Equatable {
    struct ActiveTurn: Equatable {
        let threadId: String
        let turnId: String

        init?(json: [String: JSONValue]) {
            guard let threadId = json["threadId"]?.stringValue,
                  let turnId = json["turnId"]?.stringValue else {
                return nil
            }
            self.threadId = threadId
            self.turnId = turnId
        }
    }

    struct PendingApproval: Equatable {
        let approvalId: String
        let method: String

        init?(json: [String: JSONValue]) {
            guard let approvalId = json["approvalId"]?.stringValue,
                  let method = json["method"]?.stringValue else {
                return nil
            }
            self.approvalId = approvalId
            self.method = method
        }
    }

    let bridgeVersion: String
    let protocolVersion: Int
    let minClientProtocolVersion: Int
    let host: String
    let port: Int
    let usesTLS: Bool
    let tokenFileValid: Bool
    let codexRunning: Bool
    let connectedClient: Bool
    let eventBufferSize: Int
    let eventReplayLimit: Int
    let activeTurnCount: Int
    let activeTurns: [ActiveTurn]
    let pendingApprovalCount: Int
    let pendingApprovals: [PendingApproval]
    let projectRootCount: Int
    let resumedThreadCount: Int
    let uptimeSeconds: Int

    var endpoint: String {
        "\(usesTLS ? "wss" : "ws")://\(host):\(port)"
    }

    init?(json: [String: JSONValue]) {
        guard let bridgeVersion = json["bridgeVersion"]?.stringValue,
              let protocolVersion = json["protocolVersion"]?.intValue,
              let host = json["host"]?.stringValue,
              let port = json["port"]?.intValue else {
            return nil
        }
        self.bridgeVersion = bridgeVersion
        self.protocolVersion = protocolVersion
        self.minClientProtocolVersion = json["minClientProtocolVersion"]?.intValue ?? 1
        self.host = host
        self.port = port
        self.usesTLS = json["usesTLS"]?.boolValue ?? false
        self.tokenFileValid = json["tokenFileValid"]?.boolValue ?? false
        self.codexRunning = json["codexRunning"]?.boolValue ?? false
        self.connectedClient = json["connectedClient"]?.boolValue ?? false
        self.eventBufferSize = json["eventBufferSize"]?.intValue ?? 0
        self.eventReplayLimit = json["eventReplayLimit"]?.intValue ?? 0
        self.activeTurnCount = json["activeTurnCount"]?.intValue ?? 0
        self.activeTurns = json["activeTurns"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return ActiveTurn(json: object)
        } ?? []
        self.pendingApprovalCount = json["pendingApprovalCount"]?.intValue ?? 0
        self.pendingApprovals = json["pendingApprovals"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return PendingApproval(json: object)
        } ?? []
        self.projectRootCount = json["projectRootCount"]?.intValue ?? 0
        self.resumedThreadCount = json["resumedThreadCount"]?.intValue ?? 0
        self.uptimeSeconds = json["uptimeSeconds"]?.intValue ?? 0
    }

    var diagnosticReport: String {
        [
            "maludex diagnostics",
            "appVersion: \(maludexClientVersion)",
            "bridgeVersion: \(bridgeVersion)",
            "protocolVersion: \(protocolVersion)",
            "minClientProtocolVersion: \(minClientProtocolVersion)",
            "endpoint: \(endpoint)",
            "pairingFileValid: \(tokenFileValid)",
            "codexRunning: \(codexRunning)",
            "connectedClient: \(connectedClient)",
            "eventBufferSize: \(eventBufferSize)",
            "eventReplayLimit: \(eventReplayLimit)",
            "activeTurnCount: \(activeTurnCount)",
            "activeTurns: \(activeTurns.map { "\($0.threadId)/\($0.turnId)" }.joined(separator: ", "))",
            "pendingApprovalCount: \(pendingApprovalCount)",
            "pendingApprovals: \(pendingApprovals.map { "\($0.approvalId)/\($0.method)" }.joined(separator: ", "))",
            "projectRootCount: \(projectRootCount)",
            "resumedThreadCount: \(resumedThreadCount)",
            "uptimeSeconds: \(uptimeSeconds)"
        ].joined(separator: "\n")
    }
}

struct ChatThreadOption: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let cwd: String
    let updatedAt: Double?
    let source: String?

    init?(json: [String: JSONValue]) {
        guard let id = json["id"]?.stringValue else {
            return nil
        }
        self.id = id
        self.title = json["title"]?.stringValue ?? json["preview"]?.stringValue ?? id
        self.preview = json["preview"]?.stringValue ?? ""
        self.cwd = json["cwd"]?.stringValue ?? ""
        self.updatedAt = json["updatedAt"]?.numberValue
        self.source = json["source"]?.stringValue
    }
}

struct RemoteTranscriptEntry: Equatable {
    let role: TranscriptRole
    let text: String
    let attachments: [TranscriptAttachment]
    let threadId: String?
    let turnId: String?
    let createdAt: Date

    init?(json: [String: JSONValue]) {
        guard let roleText = json["role"]?.stringValue,
              let role = TranscriptRole(rawValue: roleText),
              let text = json["text"]?.stringValue else {
            return nil
        }
        self.role = role
        self.text = text
        self.attachments = json["attachments"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return TranscriptAttachment(json: object)
        } ?? []
        self.threadId = json["threadId"]?.stringValue
        self.turnId = json["turnId"]?.stringValue
        if let timestamp = json["createdAt"]?.numberValue {
            self.createdAt = Date(timeIntervalSince1970: timestamp)
        } else {
            self.createdAt = Date()
        }
    }

    var transcriptEntry: TranscriptEntry {
        TranscriptEntry(
            role: role,
            text: text,
            isStreaming: false,
            attachments: attachments,
            threadId: threadId,
            turnId: turnId,
            createdAt: createdAt
        )
    }
}

extension TranscriptAttachment {
    init?(json: [String: JSONValue]) {
        guard let kindText = json["kind"]?.stringValue,
              let kind = TranscriptAttachmentKind(rawValue: kindText),
              let filename = json["filename"]?.stringValue else {
            return nil
        }
        self.init(
            kind: kind,
            filename: filename,
            mimeType: json["mimeType"]?.stringValue,
            byteCount: json["byteCount"]?.numberValue.map(Int.init),
            path: json["path"]?.stringValue,
            previewDataBase64: json["previewDataBase64"]?.stringValue
        )
    }
}

struct MobileAttachment: Identifiable, Equatable {
    enum Kind: String {
        case image
        case file
    }

    let id = UUID()
    let kind: Kind
    let filename: String
    let mimeType: String?
    let data: Data

    var byteCount: Int {
        data.count
    }

    var payload: [String: JSONValue] {
        var value: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "filename": .string(filename),
            "dataBase64": .string(data.base64EncodedString())
        ]
        if let mimeType {
            value["mimeType"] = .string(mimeType)
        }
        return value
    }

    var transcriptAttachment: TranscriptAttachment {
        TranscriptAttachment(
            kind: kind == .image ? .image : .file,
            filename: filename,
            mimeType: mimeType,
            byteCount: data.count,
            previewDataBase64: kind == .image && data.count <= 3 * 1024 * 1024 ? data.base64EncodedString() : nil
        )
    }
}
