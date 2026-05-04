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
let maludexClientVersion = "0.4.3"

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
