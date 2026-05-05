import Foundation

public enum ControlCenterAction: Equatable {
    case status
    case update
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
        if action == .update {
            try await updateRepository()
        }
        try await ensureDoctorBuild()
        let output = try await runTool(
            command: "node",
            arguments: ["dist/bridge/src/doctor-cli.js"] + arguments(for: action),
            currentDirectory: repoRoot
        )
        return try JSONDecoder().decode(DoctorReport.self, from: Data(output.utf8))
    }

    public func mobileHandoff(limit: Int = 5) async throws -> MobileHandoffReport {
        try await ensureDoctorBuild()
        let boundedLimit = max(1, min(limit, 50))
        let output = try await runTool(
            command: "node",
            arguments: ["dist/bridge/src/mobile-handoff-cli.js", "--json", "--limit", "\(boundedLimit)"],
            currentDirectory: repoRoot
        )
        return try JSONDecoder().decode(MobileHandoffReport.self, from: Data(output.utf8))
    }

    public var redactedReportCommand: String {
        "node dist/bridge/src/doctor-cli.js --json"
    }

    public func mobileHandoffCommand(limit: Int = 5) -> String {
        let boundedLimit = max(1, min(limit, 50))
        return "node dist/bridge/src/mobile-handoff-cli.js --json --limit \(boundedLimit)"
    }

    public var updateCommand: String {
        "git pull --ff-only && npm ci && npm run build && node dist/bridge/src/doctor-cli.js --restart --json"
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
        case .update:
            ["--restart", "--json"]
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

    private func updateRepository() async throws {
        _ = try await runTool(command: "git", arguments: ["pull", "--ff-only"], currentDirectory: repoRoot)
        _ = try await runTool(command: "npm", arguments: ["ci"], currentDirectory: repoRoot)
        _ = try await runTool(command: "npm", arguments: ["run", "build"], currentDirectory: repoRoot)
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]? = nil
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            if let environment {
                process.environment = environment
            }

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
            currentDirectory: currentDirectory,
            environment: ToolExecutableResolver.executionEnvironment(for: tool)
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
    static let managedShellBootstrap = """
    if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; command -v nvm >/dev/null 2>&1 && nvm use --silent default >/dev/null 2>&1 || true; fi; if [ -s "$HOME/.asdf/asdf.sh" ]; then . "$HOME/.asdf/asdf.sh" >/dev/null 2>&1; fi; if [ -s "$HOME/.local/share/mise/mise.sh" ]; then . "$HOME/.local/share/mise/mise.sh" >/dev/null 2>&1; fi; exec "$@"
    """

    static func executionEnvironment(
        for tool: ToolExecutable,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment
        environment["PATH"] = pathValue(including: tool, environment: baseEnvironment)
        return environment
    }

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

        for candidate in defaultCandidatePaths(
            for: command,
            homeDirectory: environment["HOME"] ?? NSHomeDirectory()
        ) where fileExists(candidate) {
            return ToolExecutable(executable: candidate, argumentsPrefix: [])
        }

        if fileExists("/bin/zsh") {
            return ToolExecutable(
                executable: "/bin/zsh",
                argumentsPrefix: ["-lc", managedShellBootstrap, "maludex-tool", command]
            )
        }

        return ToolExecutable(executable: "/usr/bin/env", argumentsPrefix: [command])
    }

    private static func pathDirectories(from pathValue: String?) -> [String] {
        pathValue?
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
    }

    private static func pathValue(including tool: ToolExecutable, environment: [String: String]) -> String {
        let homeDirectory = environment["HOME"] ?? NSHomeDirectory()
        var directories: [String] = []
        if tool.executable.hasPrefix("/") {
            let toolDirectory = URL(fileURLWithPath: tool.executable).deletingLastPathComponent().path
            directories.append(toolDirectory)
        }
        directories.append(contentsOf: pathDirectories(from: environment["PATH"]))
        directories.append(contentsOf: defaultCandidatePaths(for: "node", homeDirectory: homeDirectory).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })
        directories.append(contentsOf: defaultCandidatePaths(for: "npm", homeDirectory: homeDirectory).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })
        directories.append(contentsOf: [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ])
        return unique(directories).joined(separator: ":")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty, !seen.contains(value) else {
                return false
            }
            seen.insert(value)
            return true
        }
    }

    private static func defaultCandidatePaths(for command: String, homeDirectory: String?) -> [String] {
        var candidates: [String] = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)"
        ]

        if let homeDirectory, !homeDirectory.isEmpty {
            candidates.append(contentsOf: [
                "\(homeDirectory)/.volta/bin/\(command)",
                "\(homeDirectory)/.asdf/shims/\(command)",
                "\(homeDirectory)/.local/share/mise/shims/\(command)",
                "\(homeDirectory)/.nvm/current/bin/\(command)",
                "\(homeDirectory)/.local/bin/\(command)"
            ])
        }

        candidates.append(contentsOf: [
            "/opt/local/bin/\(command)",
            "/sw/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)"
        ])

        return candidates
    }
}
