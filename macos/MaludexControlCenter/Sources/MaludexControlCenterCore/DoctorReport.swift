import Foundation

public enum DoctorStatus: String, Codable, Equatable {
    case healthy
    case warning
    case error
}

public enum ControlCenterLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case korean = "ko"

    public static let fallback = ControlCenterLanguage.english

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .english:
            return "English"
        case .korean:
            return "한국어"
        }
    }
}

public struct ControlCenterCopy: Equatable {
    public let language: ControlCenterLanguage

    public init(language: ControlCenterLanguage) {
        self.language = language
    }

    public init(languageCode: String) {
        self.language = ControlCenterLanguage(rawValue: languageCode) ?? .fallback
    }

    public var appSubtitle: String { text("Control Center", "컨트롤 센터") }
    public var languageLabel: String { text("Language", "언어") }
    public var refreshButton: String { text("Refresh", "새로고침") }
    public var okButton: String { text("OK", "확인") }
    public var repositoryPathPlaceholder: String { text("Repository path", "레포지토리 경로") }
    public var chooseButton: String { text("Choose", "선택") }
    public var bridgeTitle: String { text("Bridge", "브릿지") }
    public var endpointTitle: String { text("Endpoint", "엔드포인트") }
    public var versionTitle: String { text("Version", "버전") }
    public var reachableValue: String { text("Reachable", "연결 가능") }
    public var offlineValue: String { text("Offline", "오프라인") }
    public var checkingValue: String { text("Checking", "확인 중") }
    public var bridgeActionsTitle: String { text("Bridge Actions", "브릿지 작업") }
    public var repairButton: String { text("Repair", "복구") }
    public var updateButton: String { text("Update", "업데이트") }
    public var restartButton: String { text("Restart", "재시작") }
    public var startButton: String { text("Start", "시작") }
    public var stopButton: String { text("Stop", "중지") }
    public var pairButton: String { text("Pair", "페어링") }
    public var rotateButton: String { text("Rotate", "토큰 교체") }
    public var diagnosticsTitle: String { text("Diagnostics", "진단") }
    public var nextStepTitle: String { text("Recommended Next Step", "추천 다음 단계") }
    public var readyNextStepTitle: String { text("Ready to pair and use", "페어링해서 사용할 준비 완료") }
    public var runActionButton: String { text("Run Action", "작업 실행") }
    public var copyReportButton: String { text("Copy Report", "리포트 복사") }
    public var repairableBadge: String { text("Repairable", "복구 가능") }
    public var pairingQRTitle: String { text("Pairing QR", "페어링 QR") }
    public var pairingQRWarning: String { text("Treat this QR like a password.", "이 QR은 비밀번호처럼 다루세요.") }
    public var mobileHandoffTitle: String { text("Mobile Handoff", "모바일 핸드오프") }
    public var mobileHandoffEmpty: String { text("No iPhone-authored requests are waiting.", "대기 중인 iPhone 요청이 없습니다.") }
    public var mobileHandoffPrivacyWarning: String { text("Private local data: prompt bodies may appear here. Avoid screenshots and public logs.", "비공개 로컬 데이터입니다. 프롬프트 본문이 표시될 수 있으니 스크린샷이나 공개 로그에 올리지 마세요.") }
    public var mobileHandoffFileLabel: String { text("Inbox file", "보관 파일") }
    public var mobileHandoffPromptLabel: String { text("Prompt", "프롬프트") }
    public var mobileHandoffAttachmentsLabel: String { text("Attachments", "첨부") }
    public var mobileHandoffThreadLabel: String { text("Thread", "스레드") }
    public var mobileHandoffCwdLabel: String { text("Project", "프로젝트") }
    public var mobileHandoffModelLabel: String { text("Model", "모델") }
    public var copyPromptButton: String { text("Copy Prompt", "프롬프트 복사") }
    public var expandPromptButton: String { text("Show Full", "전체 보기") }
    public var collapsePromptButton: String { text("Collapse", "접기") }
    public var copyQRImageButton: String { text("Copy QR Image", "QR 이미지 복사") }
    public var revealQRImageButton: String { text("Reveal in Finder", "Finder에서 보기") }

    public func statusLabel(_ status: DoctorStatus) -> String {
        switch status {
        case .healthy:
            return text("Healthy", "정상")
        case .warning:
            return text("Needs Attention", "확인 필요")
        case .error:
            return text("Error", "오류")
        }
    }

    public func recommendedActionTitle(_ action: String) -> String {
        switch action {
        case "repair":
            return repairButton
        case "update":
            return updateButton
        case "start":
            return startButton
        case "stop":
            return stopButton
        case "restart":
            return restartButton
        default:
            return runActionButton
        }
    }

    private func text(_ english: String, _ korean: String) -> String {
        language == .korean ? korean : english
    }
}

public struct MobileHandoffReport: Codable, Equatable {
    public let file: String
    public let entries: [MobileHandoffEntry]
}

public struct MobileHandoffEntry: Codable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let createdAt: String
    public let source: String
    public let kind: String
    public let threadId: String
    public let turnId: String?
    public let cwd: String?
    public let model: String?
    public let role: String?
    public let prompt: String
    public let promptBytes: Int
    public let attachments: [MobileHandoffAttachment]

    public var shortThreadId: String {
        shortIdentifier(threadId)
    }

    public var shortTurnId: String? {
        turnId.map(shortIdentifier)
    }

    public func promptPreview(maxCharacters: Int = 180) -> String {
        let normalized = prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > maxCharacters else {
            return normalized
        }
        return "\(String(normalized.prefix(max(0, maxCharacters))))..."
    }
}

public struct MobileHandoffAttachment: Codable, Equatable, Identifiable {
    public let kind: String
    public let filename: String
    public let mimeType: String?
    public let bytes: Int

    public var id: String {
        "\(kind):\(filename):\(bytes)"
    }
}

public struct DoctorIssue: Codable, Equatable, Identifiable {
    public var id: String { code }
    public let code: String
    public let severity: String
    public let title: String
    public let detail: String
    public let repairable: Bool
}

private func shortIdentifier(_ value: String) -> String {
    value.count <= 10 ? value : "\(String(value.prefix(8)))..."
}

public struct LaunchAgentStatus: Codable, Equatable {
    public let exists: Bool
    public let plistPath: String
    public let workingDirectory: String?
    public let programArguments: [String]?
    public let state: String?
    public let lastExitCode: String?
}

public struct TokenFileStatus: Codable, Equatable {
    public let path: String
    public let exists: Bool
    public let mode: String?
    public let isFile: Bool?
    public let bytes: Int?
}

public struct BridgeStatus: Codable, Equatable {
    public let reachable: Bool
    public let host: String?
    public let port: Int?
    public let bridgeVersion: String?
    public let error: String?
}

public struct DoctorReport: Codable, Equatable {
    public let status: DoctorStatus
    public let repairable: Bool
    public let primaryAction: String
    public let summary: String
    public let generatedAt: String
    public let repoRoot: String
    public let packageVersion: String
    public let launchAgent: LaunchAgentStatus?
    public let tokenFile: TokenFileStatus?
    public let bridge: BridgeStatus?
    public let tailscaleIp: String?
    public let issues: [DoctorIssue]

    public var statusLabel: String {
        switch status {
        case .healthy:
            "Healthy"
        case .warning:
            "Needs Attention"
        case .error:
            "Error"
        }
    }

    public var endpoint: String {
        guard let host = bridge?.host, let port = bridge?.port else {
            return "Not configured"
        }
        return "\(host):\(port)"
    }
}
