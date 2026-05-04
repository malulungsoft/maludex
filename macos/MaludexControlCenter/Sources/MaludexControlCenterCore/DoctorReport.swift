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
    public var restartButton: String { text("Restart", "재시작") }
    public var startButton: String { text("Start", "시작") }
    public var stopButton: String { text("Stop", "중지") }
    public var pairButton: String { text("Pair", "페어링") }
    public var rotateButton: String { text("Rotate", "토큰 교체") }
    public var diagnosticsTitle: String { text("Diagnostics", "진단") }
    public var copyReportButton: String { text("Copy Report", "리포트 복사") }
    public var repairableBadge: String { text("Repairable", "복구 가능") }
    public var pairingQRTitle: String { text("Pairing QR", "페어링 QR") }
    public var pairingQRWarning: String { text("Treat this QR like a password.", "이 QR은 비밀번호처럼 다루세요.") }

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

    private func text(_ english: String, _ korean: String) -> String {
        language == .korean ? korean : english
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
