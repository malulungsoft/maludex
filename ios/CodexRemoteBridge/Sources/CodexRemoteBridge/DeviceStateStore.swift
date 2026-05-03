import Foundation
import Security

protocol PreferencesStore: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ value: Data, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferencesStore {
    func setData(_ value: Data, forKey key: String) {
        set(value, forKey: key)
    }
}

protocol SecretStore: AnyObject {
    func save(_ token: String) throws
    func save(_ token: String, for key: String) throws
    func load() throws -> String?
    func load(for key: String) throws -> String?
    func delete() throws
    func delete(for key: String) throws
}

struct SavedBridge: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var host: String
    var port: Int
    var usesTLS: Bool
    var updatedAt: Date

    var endpoint: String {
        "\(usesTLS ? "wss" : "ws")://\(host):\(port)"
    }

    init(pairing: Pairing, now: Date = Date()) {
        self.id = pairing.id
        self.label = pairing.label ?? defaultBridgeLabel(host: pairing.host, port: pairing.port)
        self.host = pairing.host
        self.port = pairing.port
        self.usesTLS = pairing.usesTLS
        self.updatedAt = now
    }
}

struct PersistedBridgeSession: Codable, Equatable {
    var selectedProjectPath: String
    var selectedModel: String
    var selectedReasoningEffort: String
    var selectedApprovalPolicy: String
    var selectedSandbox: String
    var autoCompactEnabled: Bool
    var autoCompactTokenLimit: Int
    var threadId: String
    var lastEventId: Int
    var transcript: [TranscriptEntry]
    var updatedAt: Date

    static let empty = PersistedBridgeSession(
        selectedProjectPath: "",
        selectedModel: "",
        selectedReasoningEffort: ReasoningEffortOption.fallback,
        selectedApprovalPolicy: ApprovalPolicyOption.onRequest.rawValue,
        selectedSandbox: SandboxOption.readOnly.rawValue,
        autoCompactEnabled: true,
        autoCompactTokenLimit: 120000,
        threadId: "",
        lastEventId: 0,
        transcript: [],
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

struct PersistedDeviceState: Codable, Equatable {
    var host: String
    var port: Int
    var usesTLS: Bool
    var selectedProjectPath: String
    var selectedModel: String
    var selectedReasoningEffort: String
    var selectedApprovalPolicy: String
    var selectedSandbox: String
    var autoCompactEnabled: Bool
    var autoCompactTokenLimit: Int
    var threadId: String
    var lastEventId: Int
    var transcript: [TranscriptEntry]
    var bridges: [SavedBridge]
    var activeBridgeId: String
    var bridgeSessions: [String: PersistedBridgeSession]
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case usesTLS
        case selectedProjectPath
        case selectedModel
        case selectedReasoningEffort
        case selectedApprovalPolicy
        case selectedSandbox
        case autoCompactEnabled
        case autoCompactTokenLimit
        case threadId
        case lastEventId
        case transcript
        case bridges
        case activeBridgeId
        case bridgeSessions
        case updatedAt
    }

    static let empty = PersistedDeviceState(
        host: "",
        port: 0,
        usesTLS: false,
        selectedProjectPath: "",
        selectedModel: "",
        selectedReasoningEffort: ReasoningEffortOption.fallback,
        selectedApprovalPolicy: ApprovalPolicyOption.onRequest.rawValue,
        selectedSandbox: SandboxOption.readOnly.rawValue,
        autoCompactEnabled: true,
        autoCompactTokenLimit: 120000,
        threadId: "",
        lastEventId: 0,
        transcript: [],
        bridges: [],
        activeBridgeId: "",
        bridgeSessions: [:],
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    init(
        host: String,
        port: Int,
        usesTLS: Bool,
        selectedProjectPath: String,
        selectedModel: String,
        selectedReasoningEffort: String,
        selectedApprovalPolicy: String,
        selectedSandbox: String,
        autoCompactEnabled: Bool,
        autoCompactTokenLimit: Int,
        threadId: String,
        lastEventId: Int,
        transcript: [TranscriptEntry],
        bridges: [SavedBridge] = [],
        activeBridgeId: String = "",
        bridgeSessions: [String: PersistedBridgeSession] = [:],
        updatedAt: Date
    ) {
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
        self.selectedProjectPath = selectedProjectPath
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.selectedApprovalPolicy = selectedApprovalPolicy
        self.selectedSandbox = selectedSandbox
        self.autoCompactEnabled = autoCompactEnabled
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.threadId = threadId
        self.lastEventId = lastEventId
        self.transcript = transcript
        self.bridges = bridges
        self.activeBridgeId = activeBridgeId
        self.bridgeSessions = bridgeSessions
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        self.usesTLS = try container.decodeIfPresent(Bool.self, forKey: .usesTLS) ?? false
        self.selectedProjectPath = try container.decodeIfPresent(String.self, forKey: .selectedProjectPath) ?? ""
        self.selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? ""
        self.selectedReasoningEffort = try container.decodeIfPresent(String.self, forKey: .selectedReasoningEffort) ?? ReasoningEffortOption.fallback
        self.selectedApprovalPolicy = try container.decodeIfPresent(String.self, forKey: .selectedApprovalPolicy) ?? ApprovalPolicyOption.onRequest.rawValue
        self.selectedSandbox = try container.decodeIfPresent(String.self, forKey: .selectedSandbox) ?? SandboxOption.readOnly.rawValue
        self.autoCompactEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCompactEnabled) ?? true
        self.autoCompactTokenLimit = try container.decodeIfPresent(Int.self, forKey: .autoCompactTokenLimit) ?? 120000
        self.threadId = try container.decodeIfPresent(String.self, forKey: .threadId) ?? ""
        self.lastEventId = try container.decodeIfPresent(Int.self, forKey: .lastEventId) ?? 0
        self.transcript = try container.decodeIfPresent([TranscriptEntry].self, forKey: .transcript) ?? []
        self.bridges = try container.decodeIfPresent([SavedBridge].self, forKey: .bridges) ?? []
        self.activeBridgeId = try container.decodeIfPresent(String.self, forKey: .activeBridgeId) ?? ""
        self.bridgeSessions = try container.decodeIfPresent([String: PersistedBridgeSession].self, forKey: .bridgeSessions) ?? [:]
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    var activeSession: PersistedBridgeSession {
        bridgeSessions[activeBridgeId] ?? currentSession
    }

    var currentSession: PersistedBridgeSession {
        PersistedBridgeSession(
            selectedProjectPath: selectedProjectPath,
            selectedModel: selectedModel,
            selectedReasoningEffort: selectedReasoningEffort,
            selectedApprovalPolicy: selectedApprovalPolicy,
            selectedSandbox: selectedSandbox,
            autoCompactEnabled: autoCompactEnabled,
            autoCompactTokenLimit: autoCompactTokenLimit,
            threadId: threadId,
            lastEventId: lastEventId,
            transcript: transcript,
            updatedAt: updatedAt
        )
    }

    mutating func apply(session: PersistedBridgeSession) {
        selectedProjectPath = session.selectedProjectPath
        selectedModel = session.selectedModel
        selectedReasoningEffort = session.selectedReasoningEffort
        selectedApprovalPolicy = session.selectedApprovalPolicy
        selectedSandbox = session.selectedSandbox
        autoCompactEnabled = session.autoCompactEnabled
        autoCompactTokenLimit = session.autoCompactTokenLimit
        threadId = session.threadId
        lastEventId = session.lastEventId
        transcript = session.transcript
    }
}

final class DeviceStateStore {
    static let stateKey = "com.local.CodexRemoteBridge.deviceState.v1"

    private let preferences: PreferencesStore
    private let secretStore: SecretStore
    private let transcriptLimit: Int

    init(
        preferences: PreferencesStore = UserDefaults.standard,
        secretStore: SecretStore = KeychainSecretStore(),
        transcriptLimit: Int = 500
    ) {
        self.preferences = preferences
        self.secretStore = secretStore
        self.transcriptLimit = transcriptLimit
    }

    func savePairing(_ pairing: Pairing) throws {
        var state = migratedState()
        let bridge = SavedBridge(pairing: pairing)
        if let index = state.bridges.firstIndex(where: { $0.id == bridge.id }) {
            state.bridges[index] = bridge
        } else {
            state.bridges.append(bridge)
        }
        if state.activeBridgeId != bridge.id, !state.activeBridgeId.isEmpty {
            state.bridgeSessions[state.activeBridgeId] = state.currentSession
        }
        let existingSession = state.bridgeSessions[bridge.id]
        state.activeBridgeId = bridge.id
        if let session = existingSession {
            state.apply(session: session)
        } else {
            state.apply(session: .empty)
            state.bridgeSessions[bridge.id] = state.currentSession
        }
        state.host = pairing.host
        state.port = pairing.port
        state.usesTLS = pairing.usesTLS
        state.updatedAt = Date()
        saveState(state)
        try secretStore.save(pairing.token, for: tokenStorageKey(forBridgeId: bridge.id))
    }

    func loadPairing(id requestedId: String? = nil) throws -> Pairing? {
        let state = migratedState()
        guard let bridge = bridgeForLoad(from: state, id: requestedId),
              let token = try secretStore.load(for: tokenStorageKey(forBridgeId: bridge.id)) ?? legacyTokenIfNeeded(for: bridge),
              !token.isEmpty else {
            return nil
        }
        return Pairing(host: bridge.host, port: bridge.port, token: token, usesTLS: bridge.usesTLS, label: bridge.label)
    }

    func hasSavedPairing() -> Bool {
        !savedBridges().isEmpty
    }

    func savedBridges() -> [SavedBridge] {
        let state = migratedState()
        return state.bridges.sorted { left, right in
            if left.id == state.activeBridgeId {
                return true
            }
            if right.id == state.activeBridgeId {
                return false
            }
            return left.updatedAt > right.updatedAt
        }
    }

    func selectBridge(id: String) throws {
        var state = migratedState()
        guard state.bridges.contains(where: { $0.id == id }) else {
            return
        }
        if !state.activeBridgeId.isEmpty {
            state.bridgeSessions[state.activeBridgeId] = state.currentSession
        }
        state.activeBridgeId = id
        state.apply(session: state.bridgeSessions[id] ?? .empty)
        if let bridge = state.bridges.first(where: { $0.id == id }) {
            state.host = bridge.host
            state.port = bridge.port
            state.usesTLS = bridge.usesTLS
        }
        state.updatedAt = Date()
        saveState(state)
    }

    func deleteBridge(id: String) throws {
        var state = migratedState()
        state.bridges.removeAll { $0.id == id }
        state.bridgeSessions.removeValue(forKey: id)
        try secretStore.delete(for: tokenStorageKey(forBridgeId: id))
        if state.activeBridgeId == id {
            state.activeBridgeId = state.bridges.first?.id ?? ""
            if let active = state.bridges.first {
                state.host = active.host
                state.port = active.port
                state.usesTLS = active.usesTLS
                state.apply(session: state.bridgeSessions[active.id] ?? .empty)
            } else {
                state.host = ""
                state.port = 0
                state.usesTLS = false
                state.apply(session: .empty)
            }
        }
        state.updatedAt = Date()
        saveState(state)
    }

    func loadSnapshot() -> PersistedDeviceState? {
        guard let data = preferences.data(forKey: Self.stateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedDeviceState.self, from: data)
    }

    func saveSnapshot(
        selectedProjectPath: String,
        selectedModel: String,
        selectedReasoningEffort: String,
        selectedApprovalPolicy: String,
        selectedSandbox: String,
        autoCompactEnabled: Bool,
        autoCompactTokenLimit: Int,
        threadId: String,
        lastEventId: Int,
        transcript: [TranscriptEntry]
    ) {
        var state = migratedState()
        state.selectedProjectPath = selectedProjectPath
        state.selectedModel = selectedModel
        state.selectedReasoningEffort = selectedReasoningEffort
        state.selectedApprovalPolicy = selectedApprovalPolicy
        state.selectedSandbox = selectedSandbox
        state.autoCompactEnabled = autoCompactEnabled
        state.autoCompactTokenLimit = autoCompactTokenLimit
        state.threadId = threadId
        state.lastEventId = lastEventId
        state.transcript = sanitizedTranscript(transcript)
        if !state.activeBridgeId.isEmpty {
            state.bridgeSessions[state.activeBridgeId] = state.currentSession
        }
        state.updatedAt = Date()
        saveState(state)
    }

    func clear() throws {
        let state = migratedState()
        for bridge in state.bridges {
            try secretStore.delete(for: tokenStorageKey(forBridgeId: bridge.id))
        }
        preferences.removeObject(forKey: Self.stateKey)
        try secretStore.delete()
    }

    private func migratedState() -> PersistedDeviceState {
        var state = loadSnapshot() ?? .empty
        if state.bridges.isEmpty, !state.host.isEmpty, state.port > 0 {
            let id = bridgeIdentifier(host: state.host, port: state.port, usesTLS: state.usesTLS)
            let bridge = SavedBridge(
                pairing: Pairing(
                    host: state.host,
                    port: state.port,
                    token: "",
                    usesTLS: state.usesTLS,
                    label: defaultBridgeLabel(host: state.host, port: state.port)
                ),
                now: state.updatedAt
            )
            state.bridges = [bridge]
            state.activeBridgeId = id
            state.bridgeSessions[id] = state.currentSession
        }
        if state.activeBridgeId.isEmpty, let first = state.bridges.first {
            state.activeBridgeId = first.id
        }
        return state
    }

    private func bridgeForLoad(from state: PersistedDeviceState, id requestedId: String?) -> SavedBridge? {
        let bridgeId = requestedId ?? state.activeBridgeId
        if !bridgeId.isEmpty,
           let bridge = state.bridges.first(where: { $0.id == bridgeId }) {
            return bridge
        }
        return state.bridges.first
    }

    private func legacyTokenIfNeeded(for bridge: SavedBridge) throws -> String? {
        guard bridge.id == bridgeIdentifier(host: bridge.host, port: bridge.port, usesTLS: bridge.usesTLS) else {
            return nil
        }
        return try secretStore.load()
    }

    private func saveState(_ state: PersistedDeviceState) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        preferences.setData(data, forKey: Self.stateKey)
    }

    private func sanitizedTranscript(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        entries.suffix(transcriptLimit).map { entry in
            var copy = entry
            copy.isStreaming = false
            return copy
        }
    }
}

final class KeychainSecretStore: SecretStore {
    private let service: String
    private let account: String

    init(
        service: String = "com.local.CodexRemoteBridge",
        account: String = "bridge-token"
    ) {
        self.service = service
        self.account = account
    }

    func save(_ token: String) throws {
        try save(token, for: account)
    }

    func save(_ token: String, for key: String) throws {
        let tokenData = Data(token.utf8)
        let query = baseQuery(account: key)
        let addQuery = query.merging([
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: tokenData] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainSecretStoreError.osStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.osStatus(status)
        }
    }

    func load() throws -> String? {
        try load(for: account)
    }

    func load(for key: String) throws -> String? {
        let query = baseQuery(account: key).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.osStatus(status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete() throws {
        try delete(for: account)
    }

    func delete(for key: String) throws {
        let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.osStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

func tokenStorageKey(forBridgeId bridgeId: String) -> String {
    "bridge-token:\(bridgeId)"
}

private func defaultBridgeLabel(host: String, port: Int) -> String {
    "\(host):\(port)"
}

enum KeychainSecretStoreError: LocalizedError {
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
