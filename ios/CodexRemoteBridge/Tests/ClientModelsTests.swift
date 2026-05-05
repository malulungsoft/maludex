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
        require(AppLanguage.fallback == .english, "app language should default to English")
        require(AppLanguage(rawValue: "ko")?.title == "한국어", "Korean language option should be available")
        require(AppCopy(language: .english).settingsTitle == "Settings", "English UI copy should be available")
        require(AppCopy(language: .korean).settingsTitle == "설정", "Korean UI copy should be available")
        require(AppCopy(language: .english).approvalRespondingTitle == "Waiting for bridge", "approval confirmation copy should be available")
        require(AppCopy(language: .korean).approvalRespondingTitle == "브릿지 확인 대기", "Korean approval confirmation copy should be available")
        require(AppCopy(language: .english).searchChatsTitle == "Search chats", "chat search copy should be available")
        require(AppCopy(language: .korean).noChatsTitle == "채팅을 찾을 수 없습니다", "Korean empty chat copy should be available")
        require(AppCopy(language: .english).searchProjectsTitle == "Search projects", "project search copy should be available")
        require(AppCopy(language: .english).favoriteProjectsTitle == "Favorites", "favorite project copy should be available")
        require(AppCopy(language: .korean).unfavoriteProjectTitle == "즐겨찾기 해제", "Korean project favorite copy should be available")
        require(AppCopy(language: .english).searchModelsTitle == "Search models", "model search copy should be available")
        require(AppCopy(language: .korean).noModelsTitle == "모델을 찾을 수 없습니다", "Korean empty model copy should be available")
        require(AppCopy(language: .korean).bridgeDefaultModelDetail == "브릿지 기본 모델", "Korean default model detail should be available")
        require(AppCopy(language: .english).quickPromptsTitle == "Quick prompts", "quick prompt copy should be available")
        require(AppCopy(language: .korean).quickPromptsTitle == "빠른 프롬프트", "Korean quick prompt copy should be available")
        require(AppCopy(language: .english).manageQuickPromptsTitle == "Manage quick prompts", "quick prompt management copy should be available")
        require(AppCopy(language: .korean).saveQuickPromptTitle == "프롬프트 저장", "Korean quick prompt save copy should be available")
        require(AppCopy(language: .english).renameBridgeTitle == "Rename bridge", "bridge rename copy should be available")
        require(AppCopy(language: .korean).bridgeNamePlaceholder == "브릿지 이름", "Korean bridge name placeholder should be available")
        require(AppCopy(language: .english).expandComposerTitle == "Expand composer", "expanded composer copy should be available")
        require(AppCopy(language: .korean).composerTitle == "프롬프트 작성", "Korean composer title should be available")
        require(AppCopy(language: .english).notificationStatusTitle("authorized") == "Authorized", "notification status copy should be available")
        require(AppCopy(language: .korean).notificationStatusTitle("denied") == "거부됨", "Korean notification status copy should be available")
        require(AppCopy(language: .english).openAppSettingsTitle == "Open iPhone Settings", "notification settings recovery copy should be available")
        require(AppCopy(language: .korean).notificationsBlockedTitle == "알림이 차단됨", "Korean notification recovery copy should be available")
        require(AppCopy(language: .english).mobileHandoffRetentionTitle == "Mobile handoff retention", "handoff retention copy should be available")
        require(AppCopy(language: .english).queuedPromptsTitle == "Queued prompts", "queued prompt diagnostics copy should be available")
        require(AppCopy(language: .korean).queuedPromptsTitle == "대기 중 프롬프트", "Korean queued prompt diagnostics copy should be available")
        require(AppCopy(language: .english).searchConversationTitle == "Search conversation", "conversation search copy should be available")
        require(AppCopy(language: .korean).noSearchResultsTitle == "검색 결과 없음", "Korean empty search copy should be available")
        require(AppCopy(languageCode: "bad").settingsTitle == "Settings", "invalid language code should fall back to English")

        let queueItem = PromptQueueItem(json: [
            "id": .string("queue-1"),
            "threadId": .string("thread-1"),
            "promptPreview": .string("긴 작업을 먼저 준비해줘"),
            "promptBytes": .number(42),
            "attachmentCount": .number(2),
            "createdAt": .string("2026-05-04T14:37:10.000Z")
        ])
        require(queueItem?.id == "queue-1", "queued prompt id should decode")
        require(queueItem?.threadId == "thread-1", "queued prompt thread should decode")
        require(queueItem?.promptPreview == "긴 작업을 먼저 준비해줘", "queued prompt preview should decode")
        require(queueItem?.attachmentCount == 2, "queued prompt attachment count should decode")

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

        let englishTemplates = PromptTemplate.builtIn(language: .english)
        require(englishTemplates.count >= 4, "built-in quick prompts should be available")
        require(englishTemplates.first?.id == "review", "review should be the first quick prompt")
        require(englishTemplates.first?.prompt.contains("Review the current changes") == true, "English quick prompt text should be useful")
        let koreanTemplates = PromptTemplate.builtIn(language: .korean)
        require(koreanTemplates.first?.title == "리뷰", "Korean quick prompt title should be localized")
        require(koreanTemplates.first?.prompt.contains("현재 변경사항") == true, "Korean quick prompt text should be localized")
        let customTemplate = PromptTemplate(id: "custom-ship", title: "Ship", prompt: "Prepare a release-ready summary.", systemImage: "paperplane")
        require(PromptTemplate.mergedBuiltIns(language: .english, custom: [customTemplate]).last == customTemplate, "custom quick prompts should appear after built-ins")

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
        require(
            transcriptSyncStatusTitle(
                lastSyncedAt: Date(timeIntervalSince1970: 988),
                isRefreshing: false,
                now: now,
                language: .english
            ) == "Last synced 12s ago",
            "English sync status should show the last synced age"
        )
        require(
            transcriptSyncStatusTitle(
                lastSyncedAt: Date(timeIntervalSince1970: 880),
                isRefreshing: false,
                now: now,
                language: .korean
            ) == "2분 전 동기화됨",
            "Korean sync status should show the last synced age"
        )
        require(
            transcriptSyncStatusTitle(
                lastSyncedAt: nil,
                isRefreshing: true,
                now: now,
                language: .english
            ) == "Syncing...",
            "sync status should expose refresh progress"
        )

        let searchableEntries = [
            TranscriptEntry(role: .user, text: "Please inspect the release checklist."),
            TranscriptEntry(
                role: .assistant,
                text: "The build passed.",
                attachments: [
                    TranscriptAttachment(kind: .file, filename: "release-notes.md", mimeType: "text/markdown", byteCount: 10)
                ]
            ),
            TranscriptEntry(role: .system, text: "Thread opened")
        ]
        let textMatches = transcriptSearchResults(entries: searchableEntries, query: "release")
        require(textMatches.count == 2, "transcript search should match text and attachment filenames")
        require(textMatches.first?.role == .user, "transcript search should preserve matching entry role")
        require(textMatches.first?.preview.contains("release checklist") == true, "transcript search should expose a readable preview")
        require(transcriptSearchResults(entries: searchableEntries, query: "   ").isEmpty, "empty transcript search should not return results")
        let longSearchHit = TranscriptEntry(role: .assistant, text: String(repeating: "Search result context. ", count: 40))
        require(transcriptEntryCanCollapse(longSearchHit), "long transcript entries should collapse by default")
        require(transcriptEntryIsCollapsed(longSearchHit, userExpanded: false, forceExpanded: false), "long transcript entries should remain collapsed until expanded")
        require(!transcriptEntryIsCollapsed(longSearchHit, userExpanded: false, forceExpanded: true), "search-selected transcript entries should be forced open")
        require(!transcriptEntryIsCollapsed(longSearchHit, userExpanded: true, forceExpanded: false), "manually expanded transcript entries should stay open")

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
        require(
            normalizedReconnectEventId(current: 42, serverLastEventId: 3) == 3,
            "event cursor should reset when the bridge restarts with a lower event id"
        )
        require(
            normalizedReconnectEventId(current: 42, serverLastEventId: 100) == 42,
            "event cursor should keep current value when the bridge is continuing"
        )
        require(
            shouldRefreshActiveChat(
                isConnected: true,
                threadId: "thread-1",
                isLoadingOlderTranscript: false,
                hasActiveTurn: false,
                now: Date(timeIntervalSince1970: 100),
                lastRefreshAt: nil,
                minimumInterval: 12
            ),
            "active desktop chats should refresh automatically after connection"
        )
        require(
            shouldRefreshActiveChat(
                isConnected: true,
                threadId: "thread-1",
                isLoadingOlderTranscript: false,
                hasActiveTurn: false,
                now: Date(timeIntervalSince1970: 120),
                lastRefreshAt: Date(timeIntervalSince1970: 100),
                minimumInterval: 12
            ),
            "active desktop chats should refresh after the sync interval"
        )
        require(
            !shouldRefreshActiveChat(
                isConnected: true,
                threadId: "thread-1",
                isLoadingOlderTranscript: false,
                hasActiveTurn: true,
                now: Date(timeIntervalSince1970: 120),
                lastRefreshAt: Date(timeIntervalSince1970: 100),
                minimumInterval: 12
            ),
            "active mobile turns should keep live streaming events in control"
        )
        require(
            shouldRefreshActiveChat(
                isConnected: true,
                threadId: "thread-1",
                isLoadingOlderTranscript: false,
                hasActiveTurn: true,
                now: Date(timeIntervalSince1970: 170),
                lastRefreshAt: Date(timeIntervalSince1970: 100),
                minimumInterval: 12,
                activeTurnLastEventAt: Date(timeIntervalSince1970: 120),
                activeTurnRecoveryInterval: 45
            ),
            "stale active turns should recover by refreshing the desktop chat"
        )
        require(
            shouldRefreshActiveChat(
                isConnected: true,
                threadId: "thread-1",
                isLoadingOlderTranscript: false,
                hasActiveTurn: true,
                now: Date(timeIntervalSince1970: 121),
                lastRefreshAt: Date(timeIntervalSince1970: 120),
                minimumInterval: 12,
                activeTurnLastEventAt: Date(timeIntervalSince1970: 121),
                activeTurnRecoveryInterval: 45,
                bypassMinimumInterval: true,
                allowActiveTurnRefresh: true
            ),
            "manual refresh should bypass the active-turn and interval guards"
        )
        require(
            !shouldRefreshActiveChat(
                isConnected: false,
                threadId: "thread-1",
                isLoadingOlderTranscript: false,
                hasActiveTurn: false,
                now: Date(timeIntervalSince1970: 120),
                lastRefreshAt: Date(timeIntervalSince1970: 100),
                minimumInterval: 12
            ),
            "disconnected clients should not request desktop chat refreshes"
        )
        let approvalNotification = mobileNotificationIntent(
            type: "approval.requested",
            method: "item/commandExecution/requestApproval",
            params: [:],
            approvalId: "approval-1"
        )
        require(approvalNotification?.title == "Approval needed", "approval requests should create a local notification")
        require(approvalNotification?.body.contains("Command approval") == true, "approval notification should identify command approvals")
        let completionNotification = mobileNotificationIntent(
            type: "codex.event",
            method: "turn/completed",
            params: ["threadId": .string("thread-1")],
            approvalId: nil
        )
        require(completionNotification?.title == "Turn finished", "turn completion should create a local notification")
        let queueFailureNotification = mobileNotificationIntent(
            type: "prompt.queue.failed",
            method: nil,
            params: ["message": .string("Model unavailable")],
            approvalId: nil
        )
        require(queueFailureNotification?.body == "Model unavailable", "queue failures should surface their message")
        require(
            mobileNotificationIntent(type: "codex.event", method: "item/agentMessage/delta", params: [:], approvalId: nil) == nil,
            "streaming deltas should not create local notifications"
        )
        require(
            shouldScheduleMobileNotification(type: "approval.requested", appIsActive: false),
            "approval notifications should be scheduled while the app is backgrounded"
        )
        require(
            !shouldScheduleMobileNotification(type: "approval.requested", appIsActive: true),
            "approval notifications should not be scheduled while the approval card is already visible"
        )
        require(
            shouldScheduleMobileNotification(type: "codex.event", appIsActive: true),
            "non-approval notifications should preserve existing scheduling behavior"
        )

        let diagnostics = BridgeDiagnostics(json: [
            "bridgeVersion": .string("0.4.3"),
            "protocolVersion": .number(1),
            "host": .string("maludex.example.com"),
            "port": .number(443),
            "usesTLS": .bool(true),
            "tokenFileValid": .bool(true),
            "codexRunning": .bool(true),
            "connectedClient": .bool(true),
            "eventBufferSize": .number(12),
            "activeTurnCount": .number(1),
            "promptQueueCount": .number(3),
            "activeTurns": .array([
                .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1")
                ])
            ]),
            "pendingApprovalCount": .number(0),
            "mobileHandoffMaxEntries": .number(50),
            "pendingApprovals": .array([
                .object([
                    "approvalId": .string("approval-1"),
                    "method": .string("item/commandExecution/requestApproval")
                ])
            ]),
            "projectRootCount": .number(2),
            "uptimeSeconds": .number(42)
        ])
        require(diagnostics?.bridgeVersion == "0.4.3", "diagnostics should decode bridge version")
        require(diagnostics?.endpoint == "wss://maludex.example.com:443", "diagnostics should expose endpoint")
        require(diagnostics?.activeTurns.first?.threadId == "thread-1", "diagnostics should decode active turn details")
        require(diagnostics?.promptQueueCount == 3, "diagnostics should decode queued prompt count")
        require(diagnostics?.pendingApprovals.first?.approvalId == "approval-1", "diagnostics should decode pending approval details")
        require(diagnostics?.mobileHandoffMaxEntries == 50, "diagnostics should decode handoff retention metadata")
        require(diagnostics?.diagnosticReport.contains("token") == false, "diagnostics report should not include bearer token material")
        require(diagnostics?.diagnosticReport.contains("mobileHandoffMaxEntries: 50") == true, "diagnostics report should include handoff retention metadata")
        require(diagnostics?.diagnosticReport.contains("promptQueueCount: 3") == true, "diagnostics report should include prompt queue count")
        require(diagnostics?.diagnosticReport.contains("thread-1") == true, "diagnostics report should include safe thread metadata")
        require(diagnostics?.diagnosticReport.contains("bridgeVersion: 0.4.3") == true, "diagnostics report should be copyable")

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
            languageCode: AppLanguage.korean.rawValue,
            autoCompactEnabled: false,
            autoCompactTokenLimit: 90000,
            threadId: "thread-1",
            promptDraft: "unfinished mobile prompt",
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
        require(restoredSnapshot?.languageCode == AppLanguage.korean.rawValue, "selected language should restore")
        require(restoredSnapshot?.autoCompactEnabled == false, "auto compact toggle should restore")
        require(restoredSnapshot?.autoCompactTokenLimit == 90000, "auto compact token limit should restore")
        require(restoredSnapshot?.threadId == "thread-1", "thread id should restore")
        require(restoredSnapshot?.promptDraft == "unfinished mobile prompt", "prompt draft should restore")
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
            languageCode: AppLanguage.english.rawValue,
            autoCompactEnabled: true,
            autoCompactTokenLimit: 120000,
            threadId: "thread-desk",
            promptDraft: "desk draft",
            lastEventId: 7,
            transcript: [TranscriptEntry(role: .assistant, text: "desk history")]
        )

        let bridges = deviceStore.savedBridges()
        require(bridges.count == 2, "multiple bridge pairings should be stored")
        require(bridges.map(\.label).contains("Studio Mac"), "first bridge label should be stored")
        require(bridges.map(\.label).contains("Desk PC"), "second bridge label should be stored")
        require(try! deviceStore.loadPairing()?.host == "100.64.1.3", "latest bridge should become active")
        try! deviceStore.selectBridge(id: bridgeIdentifier(host: "100.64.1.2", port: 8765, usesTLS: false))
        deviceStore.renameBridge(id: bridgeIdentifier(host: "100.64.1.2", port: 8765, usesTLS: false), label: "Studio Renamed")
        require(deviceStore.savedBridges().first(where: { $0.id == bridgeIdentifier(host: "100.64.1.2", port: 8765, usesTLS: false) })?.label == "Studio Renamed", "renaming a bridge should persist its label")
        require(try! deviceStore.loadPairing()?.label == "Studio Renamed", "renamed bridge label should load with the pairing")
        require(try! deviceStore.loadPairing()?.host == "100.64.1.2", "selected bridge should load its token")
        require(deviceStore.loadSnapshot()?.threadId == "thread-1", "switching bridge should restore that bridge session")
        require(deviceStore.loadSnapshot()?.promptDraft == "unfinished mobile prompt", "switching bridge should restore that bridge draft")
        try! deviceStore.selectBridge(id: bridgeIdentifier(host: "100.64.1.3", port: 9876, usesTLS: false))
        require(deviceStore.loadSnapshot()?.threadId == "thread-desk", "second bridge session should restore independently")
        require(deviceStore.loadSnapshot()?.promptDraft == "desk draft", "second bridge draft should restore independently")
        deviceStore.saveCustomPromptTemplate(customTemplate)
        deviceStore.saveCustomPromptTemplate(PromptTemplate(id: "custom-docs", title: "Docs", prompt: "Update the README.", systemImage: "doc.text"))
        require(deviceStore.customPromptTemplates().map(\.id) == ["custom-ship", "custom-docs"], "custom prompt templates should persist in insertion order")
        deviceStore.moveCustomPromptTemplate(id: "custom-docs", direction: -1)
        require(deviceStore.customPromptTemplates().map(\.id) == ["custom-docs", "custom-ship"], "custom prompt templates should support reordering")
        deviceStore.deleteCustomPromptTemplate(id: "custom-docs")
        require(deviceStore.customPromptTemplates().map(\.id) == ["custom-ship"], "custom prompt templates should support deletion")
        deviceStore.toggleFavoriteProject(path: "/Users/example/Desk")
        deviceStore.toggleFavoriteProject(path: "/Users/example/App")
        require(deviceStore.favoriteProjectPaths() == ["/Users/example/Desk", "/Users/example/App"], "favorite projects should persist in selection order")
        deviceStore.toggleFavoriteProject(path: "/Users/example/Desk")
        require(deviceStore.favoriteProjectPaths() == ["/Users/example/App"], "favorite projects should be removable")
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
            languageCode: AppLanguage.korean.rawValue,
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
