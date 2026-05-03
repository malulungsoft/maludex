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
