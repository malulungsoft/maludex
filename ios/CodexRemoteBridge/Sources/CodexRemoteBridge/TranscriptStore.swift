import Foundation

enum TranscriptRole: String, Codable, Equatable {
    case user
    case assistant
    case system
}

enum TranscriptAttachmentKind: String, Codable, Equatable {
    case image
    case file
}

struct TranscriptAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: TranscriptAttachmentKind
    let filename: String
    let mimeType: String?
    let byteCount: Int?
    let path: String?
    let previewDataBase64: String?

    init(
        id: UUID = UUID(),
        kind: TranscriptAttachmentKind,
        filename: String,
        mimeType: String? = nil,
        byteCount: Int? = nil,
        path: String? = nil,
        previewDataBase64: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.path = path
        self.previewDataBase64 = previewDataBase64
    }
}

struct TranscriptEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let role: TranscriptRole
    var text: String
    var isStreaming: Bool
    var attachments: [TranscriptAttachment]
    let threadId: String?
    let turnId: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case isStreaming
        case attachments
        case threadId
        case turnId
        case createdAt
    }

    init(
        id: UUID = UUID(),
        role: TranscriptRole,
        text: String,
        isStreaming: Bool = false,
        attachments: [TranscriptAttachment] = [],
        threadId: String? = nil,
        turnId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.attachments = attachments
        self.threadId = threadId
        self.turnId = turnId
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(TranscriptRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        self.attachments = try container.decodeIfPresent([TranscriptAttachment].self, forKey: .attachments) ?? []
        self.threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        self.turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

final class TranscriptStore {
    private(set) var entries: [TranscriptEntry] = []

    func addUserPrompt(_ text: String, attachments: [TranscriptAttachment] = []) {
        entries.append(TranscriptEntry(role: .user, text: text, attachments: attachments))
    }

    func addSystemMessage(_ text: String) {
        entries.append(TranscriptEntry(role: .system, text: text))
    }

    func replace(with newEntries: [TranscriptEntry]) {
        entries = newEntries
    }

    func appendAssistantDelta(_ threadId: String, turnId: String, text: String) {
        if let index = entries.lastIndex(where: {
            $0.role == .assistant && $0.threadId == threadId && $0.turnId == turnId && $0.isStreaming
        }) {
            entries[index].text += text
            return
        }

        entries.append(
            TranscriptEntry(
                role: .assistant,
                text: text,
                isStreaming: true,
                threadId: threadId,
                turnId: turnId
            )
        )
    }

    func finishAssistantTurn(_ threadId: String, turnId: String) {
        guard let index = entries.lastIndex(where: {
            $0.role == .assistant && $0.threadId == threadId && $0.turnId == turnId
        }) else {
            return
        }
        entries[index].isStreaming = false
    }
}
