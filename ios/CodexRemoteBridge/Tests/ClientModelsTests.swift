import Foundation

@main
struct ClientModelsTests {
    static func main() {
        let project = ProjectOption(json: [
            "path": .string("/Users/example/App"),
            "name": .string("App"),
            "source": .string("recent"),
            "updatedAt": .number(10)
        ])
        require(project?.id == "/Users/example/App", "project id should be the path")
        require(project?.name == "App", "project name should decode")
        require(project?.source == "recent", "project source should decode")

        let model = CodexModelOption(json: [
            "model": .string("gpt-5.5"),
            "displayName": .string("GPT-5.5"),
            "description": .string("Frontier"),
            "inputModalities": .array([.string("text"), .string("image")]),
            "supportedReasoningEfforts": .array([.string("low"), .string("medium"), .string("high")]),
            "defaultReasoningEffort": .string("medium"),
            "isDefault": .bool(true)
        ])
        require(model?.id == "gpt-5.5", "model id should use the model wire value")
        require(model?.supportsImages == true, "model should expose image support")
        require(model?.supportedReasoningEfforts == ["low", "medium", "high"], "model should expose supported intelligence levels")
        require(model?.defaultReasoningEffort == "medium", "model should expose default intelligence level")

        let chat = ChatThreadOption(json: [
            "id": .string("thread-1"),
            "title": .string("Desktop chat"),
            "preview": .string("hello"),
            "cwd": .string("/Users/example/App"),
            "updatedAt": .number(10)
        ])
        require(chat?.id == "thread-1", "chat id should decode")
        require(chat?.title == "Desktop chat", "chat title should decode")

        let history = RemoteTranscriptEntry(json: [
            "role": .string("assistant"),
            "text": .string("past answer"),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "createdAt": .number(10),
            "attachments": .array([
                .object([
                    "kind": .string("image"),
                    "filename": .string("photo.png"),
                    "mimeType": .string("image/png"),
                    "byteCount": .number(8),
                    "previewDataBase64": .string(Data("image".utf8).base64EncodedString())
                ]),
                .object([
                    "kind": .string("file"),
                    "filename": .string("notes.pdf"),
                    "mimeType": .string("application/pdf"),
                    "byteCount": .number(5)
                ])
            ])
        ])
        require(history?.role == .assistant, "remote transcript role should decode")
        require(history?.text == "past answer", "remote transcript text should decode")
        require(history?.attachments.count == 2, "remote transcript attachments should decode")
        require(history?.transcriptEntry.attachments.first?.filename == "photo.png", "transcript entry should carry attachments")

        let now = Date(timeIntervalSince1970: 1_000)
        require(messageRelativeTime(from: Date(timeIntervalSince1970: 970), now: now) == "방금 전", "message time should show just now under one minute")
        require(messageRelativeTime(from: Date(timeIntervalSince1970: 880), now: now) == "2분 전", "message time should show minutes")
        require(messageRelativeTime(from: Date(timeIntervalSince1970: 1_000 - 7_200), now: now) == "2시간 전", "message time should show hours")
        require(messageRelativeTime(from: Date(timeIntervalSince1970: 1_000 - 172_800), now: now) == "2일 전", "message time should show days")

        let attachment = MobileAttachment(
            kind: .file,
            filename: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )
        let payload = attachment.payload
        require(payload["kind"] == .string("file"), "attachment kind should encode")
        require(payload["filename"] == .string("notes.txt"), "attachment filename should encode")
        require(payload["mimeType"] == .string("text/plain"), "attachment mime should encode")
        require(payload["dataBase64"] == .string(Data("hello".utf8).base64EncodedString()), "attachment data should be base64")

        let token = String(repeating: "a", count: 40)
        let maludexPairing = try! Pairing(uri: "maludex://pair?host=100.64.1.2&port=8765&token=\(token)&tls=0&name=Studio%20Mac")
        require(maludexPairing.host == "100.64.1.2", "maludex pairing URI should decode")
        require(maludexPairing.label == "Studio Mac", "maludex pairing URI should decode bridge label")
        let legacyPairing = try! Pairing(uri: "codex-remote://pair?host=100.64.1.2&port=8765&token=\(token)&tls=0")
        require(legacyPairing.token == token, "legacy pairing URI should remain supported")

        let koreanLocale = preferredSpeechLocaleIdentifier(
            preferredLanguages: ["ko-KR", "en-US"],
            availableLocaleIdentifiers: Set(["en-US", "ko-KR"])
        )
        require(koreanLocale == "ko-KR", "speech input should prefer Korean recognition when available")
        let koreanFallbackLocale = preferredSpeechLocaleIdentifier(
            preferredLanguages: ["ko"],
            availableLocaleIdentifiers: Set(["en-US", "ko-KR"])
        )
        require(koreanFallbackLocale == "ko-KR", "speech input should map Korean language preference to ko-KR")
        let koreanOverrideLocale = preferredSpeechLocaleIdentifier(
            preferredLanguages: ["en-US"],
            availableLocaleIdentifiers: Set(["en-US", "ko-KR"])
        )
        require(koreanOverrideLocale == "ko-KR", "speech input should use Korean by default even when the device language is English")

        let compatibleReady: [String: JSONValue] = [
            "protocolVersion": .number(1),
            "minClientProtocolVersion": .number(1),
            "bridgeVersion": .string("0.1.2")
        ]
        require(bridgeCompatibilityWarning(readyMessage: compatibleReady) == nil, "compatible bridge should not warn")
        let futureReady: [String: JSONValue] = [
            "protocolVersion": .number(3),
            "minClientProtocolVersion": .number(2),
            "bridgeVersion": .string("0.3.0")
        ]
        require(
            bridgeCompatibilityWarning(readyMessage: futureReady)?.contains("Update maludex iPhone app") == true,
            "future bridge protocol should ask the user to update the app"
        )
        let oldReady: [String: JSONValue] = [
            "protocolVersion": .number(0),
            "minClientProtocolVersion": .number(0),
            "bridgeVersion": .string("0.0.9")
        ]
        require(
            bridgeCompatibilityWarning(readyMessage: oldReady)?.contains("Update maludex bridge") == true,
            "old bridge protocol should ask the user to update the bridge"
        )

        let authError = userFacingBridgeError([
            "code": .string("auth_failed"),
            "message": .string("Unauthorized")
        ])
        require(authError.contains("pair again"), "auth failures should explain pairing recovery")
        let inactiveTurnError = userFacingBridgeError([
            "code": .string("bridge_error"),
            "message": .string("No active turn is tracked for thread thread-1.")
        ])
        require(inactiveTurnError.contains("No active Codex turn"), "inactive turn errors should be user-friendly")
        require(
            userFacingConnectionError("The Internet connection appears to be offline.").contains("Mac bridge"),
            "offline connection errors should explain bridge reachability"
        )
        let diagnostics = BridgeDiagnostics(json: [
            "bridgeVersion": .string("0.4.0"),
            "protocolVersion": .number(1),
            "host": .string("maludex.example.com"),
            "port": .number(443),
            "usesTLS": .bool(true),
            "tokenFileValid": .bool(true),
            "codexRunning": .bool(true),
            "connectedClient": .bool(true),
            "eventBufferSize": .number(12),
            "activeTurnCount": .number(1),
            "activeTurns": .array([
                .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1")
                ])
            ]),
            "pendingApprovalCount": .number(0),
            "pendingApprovals": .array([
                .object([
                    "approvalId": .string("approval-1"),
                    "method": .string("item/commandExecution/requestApproval")
                ])
            ]),
            "projectRootCount": .number(2),
            "uptimeSeconds": .number(42)
        ])
        require(diagnostics?.bridgeVersion == "0.4.0", "diagnostics should decode bridge version")
        require(diagnostics?.endpoint == "wss://maludex.example.com:443", "diagnostics should expose endpoint")
        require(diagnostics?.activeTurns.first?.threadId == "thread-1", "diagnostics should decode active turn details")
        require(diagnostics?.pendingApprovals.first?.approvalId == "approval-1", "diagnostics should decode pending approval details")
        require(diagnostics?.diagnosticReport.contains("token") == false, "diagnostics report should not include bearer token material")
        require(diagnostics?.diagnosticReport.contains("thread-1") == true, "diagnostics report should include safe thread metadata")
        require(diagnostics?.diagnosticReport.contains("bridgeVersion: 0.4.0") == true, "diagnostics report should be copyable")

        let preferences = MemoryPreferencesStore()
        let secrets = MemorySecretStore()
        let deviceStore = DeviceStateStore(preferences: preferences, secretStore: secrets)
        let pairing = maludexPairing
        try! deviceStore.savePairing(pairing)
        deviceStore.saveSnapshot(
            selectedProjectPath: "/Users/example/App",
            selectedModel: "gpt-5.5",
            selectedReasoningEffort: "high",
            selectedApprovalPolicy: "on-failure",
            selectedSandbox: "workspace-write",
            autoCompactEnabled: false,
            autoCompactTokenLimit: 90000,
            threadId: "thread-1",
            lastEventId: 42,
            transcript: [
                TranscriptEntry(
                    role: .user,
                    text: "saved prompt",
                    attachments: [
                        TranscriptAttachment(
                            kind: .file,
                            filename: "notes.pdf",
                            mimeType: "application/pdf",
                            byteCount: 5
                        )
                    ],
                    threadId: "thread-1",
                    turnId: "turn-1",
                    createdAt: Date(timeIntervalSince1970: 10)
                )
            ]
        )

        let restoredPairing = try! deviceStore.loadPairing()
        require(restoredPairing?.host == "100.64.1.2", "pairing host should restore")
        require(restoredPairing?.token == token, "pairing token should restore from secret storage")
        let restoredSnapshot = deviceStore.loadSnapshot()
        require(restoredSnapshot?.selectedProjectPath == "/Users/example/App", "selected project should restore")
        require(restoredSnapshot?.selectedModel == "gpt-5.5", "selected model should restore")
        require(restoredSnapshot?.selectedReasoningEffort == "high", "selected intelligence should restore")
        require(restoredSnapshot?.selectedApprovalPolicy == "on-failure", "selected approval policy should restore")
        require(restoredSnapshot?.selectedSandbox == "workspace-write", "selected sandbox should restore")
        require(restoredSnapshot?.autoCompactEnabled == false, "auto compact toggle should restore")
        require(restoredSnapshot?.autoCompactTokenLimit == 90000, "auto compact token limit should restore")
        require(restoredSnapshot?.threadId == "thread-1", "thread id should restore")
        require(restoredSnapshot?.lastEventId == 42, "last event id should restore")
        require(restoredSnapshot?.transcript.first?.text == "saved prompt", "transcript should restore")
        require(restoredSnapshot?.transcript.first?.attachments.first?.filename == "notes.pdf", "transcript attachments should restore")
        let storedMetadata = String(data: preferences.data(forKey: DeviceStateStore.stateKey)!, encoding: .utf8)!
        require(!storedMetadata.contains(token), "raw bearer token should not be stored in user defaults metadata")

        let secondToken = String(repeating: "b", count: 40)
        let secondPairing = Pairing(host: "100.64.1.3", port: 9876, token: secondToken, usesTLS: false, label: "Desk PC")
        try! deviceStore.savePairing(secondPairing)
        deviceStore.saveSnapshot(
            selectedProjectPath: "/Users/example/Desk",
            selectedModel: "gpt-5.4-mini",
            selectedReasoningEffort: "medium",
            selectedApprovalPolicy: "on-request",
            selectedSandbox: "read-only",
            autoCompactEnabled: true,
            autoCompactTokenLimit: 120000,
            threadId: "thread-desk",
            lastEventId: 7,
            transcript: [TranscriptEntry(role: .assistant, text: "desk history")]
        )

        let bridges = deviceStore.savedBridges()
        require(bridges.count == 2, "multiple bridge pairings should be stored")
        require(bridges.map(\.label).contains("Studio Mac"), "first bridge label should be stored")
        require(bridges.map(\.label).contains("Desk PC"), "second bridge label should be stored")
        require(try! deviceStore.loadPairing()?.host == "100.64.1.3", "latest bridge should become active")
        try! deviceStore.selectBridge(id: bridgeIdentifier(host: "100.64.1.2", port: 8765, usesTLS: false))
        require(try! deviceStore.loadPairing()?.host == "100.64.1.2", "selected bridge should load its token")
        require(deviceStore.loadSnapshot()?.threadId == "thread-1", "switching bridge should restore that bridge session")
        try! deviceStore.selectBridge(id: bridgeIdentifier(host: "100.64.1.3", port: 9876, usesTLS: false))
        require(deviceStore.loadSnapshot()?.threadId == "thread-desk", "second bridge session should restore independently")
        try! deviceStore.deleteBridge(id: bridgeIdentifier(host: "100.64.1.3", port: 9876, usesTLS: false))
        require(deviceStore.savedBridges().count == 1, "deleting a bridge should remove it from the switcher")
        require(try! secrets.load(for: tokenStorageKey(forBridgeId: bridgeIdentifier(host: "100.64.1.3", port: 9876, usesTLS: false))) == nil, "deleting a bridge should delete its token")
        let multiStoredMetadata = String(data: preferences.data(forKey: DeviceStateStore.stateKey)!, encoding: .utf8)!
        require(!multiStoredMetadata.contains(token), "first raw bearer token should not be stored in metadata")
        require(!multiStoredMetadata.contains(secondToken), "second raw bearer token should not be stored in metadata")

        let stalePreferences = MemoryPreferencesStore()
        let staleStore = DeviceStateStore(preferences: stalePreferences, secretStore: MemorySecretStore())
        let firstBridge = SavedBridge(pairing: Pairing(host: "100.64.1.10", port: 8765, token: token, usesTLS: false, label: "Studio"))
        let activeBridge = SavedBridge(pairing: Pairing(host: "100.64.1.11", port: 8765, token: secondToken, usesTLS: false, label: "Laptop"))
        let staleTopLevelState = PersistedDeviceState(
            host: activeBridge.host,
            port: activeBridge.port,
            usesTLS: activeBridge.usesTLS,
            selectedProjectPath: "/Users/example/Stale",
            selectedModel: "gpt-5.5",
            selectedReasoningEffort: "high",
            selectedApprovalPolicy: "on-failure",
            selectedSandbox: "workspace-write",
            autoCompactEnabled: false,
            autoCompactTokenLimit: 90000,
            threadId: "thread-stale",
            lastEventId: 99,
            transcript: [TranscriptEntry(role: .assistant, text: "stale history")],
            bridges: [firstBridge, activeBridge],
            activeBridgeId: activeBridge.id,
            bridgeSessions: [
                firstBridge.id: PersistedBridgeSession(
                    selectedProjectPath: "/Users/example/Studio",
                    selectedModel: "gpt-5.4",
                    selectedReasoningEffort: "medium",
                    selectedApprovalPolicy: "on-request",
                    selectedSandbox: "read-only",
                    autoCompactEnabled: true,
                    autoCompactTokenLimit: 120000,
                    threadId: "thread-studio",
                    lastEventId: 1,
                    transcript: [TranscriptEntry(role: .assistant, text: "studio history")],
                    updatedAt: Date(timeIntervalSince1970: 1)
                ),
                activeBridge.id: PersistedBridgeSession(
                    selectedProjectPath: "/Users/example/Laptop",
                    selectedModel: "gpt-5.4-mini",
                    selectedReasoningEffort: "low",
                    selectedApprovalPolicy: "on-request",
                    selectedSandbox: "read-only",
                    autoCompactEnabled: true,
                    autoCompactTokenLimit: 120000,
                    threadId: "thread-laptop",
                    lastEventId: 2,
                    transcript: [TranscriptEntry(role: .assistant, text: "laptop history")],
                    updatedAt: Date(timeIntervalSince1970: 2)
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        stalePreferences.setData(try! JSONEncoder().encode(staleTopLevelState), forKey: DeviceStateStore.stateKey)
        let normalizedStaleSnapshot = staleStore.loadSnapshot()
        require(normalizedStaleSnapshot?.threadId == "thread-laptop", "active bridge session should override stale top-level thread")
        require(normalizedStaleSnapshot?.transcript.first?.text == "laptop history", "active bridge transcript should not bleed across pairings")

        let legacyEntryJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "role": "user",
          "text": "legacy",
          "isStreaming": false,
          "threadId": "thread-1",
          "turnId": "turn-1",
          "createdAt": 10
        }
        """.data(using: .utf8)!
        let legacyEntry = try! JSONDecoder().decode(TranscriptEntry.self, from: legacyEntryJSON)
        require(legacyEntry.attachments.isEmpty, "legacy transcript entries without attachments should still decode")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("failed: \(message)\n", stderr)
            exit(1)
        }
    }
}

final class MemoryPreferencesStore: PreferencesStore {
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        values[key]
    }

    func setData(_ value: Data, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

final class MemorySecretStore: SecretStore {
    private var value: String?
    private var keyedValues: [String: String] = [:]

    func save(_ token: String) throws {
        value = token
    }

    func save(_ token: String, for key: String) throws {
        keyedValues[key] = token
    }

    func load() throws -> String? {
        value
    }

    func load(for key: String) throws -> String? {
        keyedValues[key]
    }

    func delete() throws {
        value = nil
    }

    func delete(for key: String) throws {
        keyedValues.removeValue(forKey: key)
    }
}
