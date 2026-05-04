import Foundation

public enum DoctorStatus: String, Codable, Equatable {
    case healthy
    case warning
    case error
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
