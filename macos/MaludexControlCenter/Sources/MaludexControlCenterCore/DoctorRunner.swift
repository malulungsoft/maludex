import Foundation

public enum ControlCenterAction {
    case status
    case repair
    case start
    case stop
    case restart
    case pairingQR(URL)
    case rotateToken(URL)
}

public struct DoctorRunner {
    public var repoRoot: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    public func run(_ action: ControlCenterAction = .status) async throws -> DoctorReport {
        try await ensureDoctorBuild()
        let output = try await runTool(
            command: "node",
            arguments: ["dist/bridge/src/doctor-cli.js"] + arguments(for: action),
            currentDirectory: repoRoot
        )
        return try JSONDecoder().decode(DoctorReport.self, from: Data(output.utf8))
    }

    public var redactedReportCommand: String {
        "node dist/bridge/src/doctor-cli.js --json"
    }

    private func ensureDoctorBuild() async throws {
        let doctorCli = repoRoot.appending(path: "dist/bridge/src/doctor-cli.js")
        if FileManager.default.fileExists(atPath: doctorCli.path) {
            return
        }
        _ = try await runTool(
            command: "npm",
            arguments: ["run", "build", "--silent"],
            currentDirectory: repoRoot
        )
    }

    private func arguments(for action: ControlCenterAction) -> [String] {
        switch action {
        case .status:
            ["--json"]
        case .repair:
            ["--repair", "--json"]
        case .start:
            ["--start", "--json"]
        case .stop:
            ["--stop", "--json"]
        case .restart:
            ["--restart", "--json"]
        case .pairingQR(let url):
            ["--pairing-qr", "--qr-file", url.path, "--json"]
        case .rotateToken(let url):
            ["--rotate-token", "--qr-file", url.path, "--json"]
        }
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw DoctorRunnerError(command: ([executable] + arguments).joined(separator: " "), output: output, error: error)
            }
            return output
        }.value
    }

    private func runTool(
        command: String,
        arguments: [String],
        currentDirectory: URL
    ) async throws -> String {
        let tool = ToolExecutableResolver.resolve(command: command)
        return try await runProcess(
            executable: tool.executable,
            arguments: tool.argumentsPrefix + arguments,
            currentDirectory: currentDirectory
        )
    }
}

public struct DoctorRunnerError: Error, LocalizedError {
    public let command: String
    public let output: String
    public let error: String

    public var errorDescription: String? {
        let detail = error.isEmpty ? output : error
        return detail.isEmpty ? "Command failed: \(command)" : detail
    }
}

struct ToolExecutable: Equatable {
    let executable: String
    let argumentsPrefix: [String]
}

enum ToolExecutableResolver {
    static func resolve(
        command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> ToolExecutable {
        let overrideKey = "MALUDEX_\(command.uppercased())_PATH"
        if let override = environment[overrideKey], fileExists(override) {
            return ToolExecutable(executable: override, argumentsPrefix: [])
        }

        for directory in pathDirectories(from: environment["PATH"]) {
            let candidate = "\(directory)/\(command)"
            if fileExists(candidate) {
                return ToolExecutable(executable: candidate, argumentsPrefix: [])
            }
        }

        for candidate in defaultCandidatePaths(for: command) where fileExists(candidate) {
            return ToolExecutable(executable: candidate, argumentsPrefix: [])
        }

        return ToolExecutable(executable: "/usr/bin/env", argumentsPrefix: [command])
    }

    private static func pathDirectories(from pathValue: String?) -> [String] {
        pathValue?
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
    }

    private static func defaultCandidatePaths(for command: String) -> [String] {
        [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/opt/local/bin/\(command)",
            "/sw/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)"
        ]
    }
}
