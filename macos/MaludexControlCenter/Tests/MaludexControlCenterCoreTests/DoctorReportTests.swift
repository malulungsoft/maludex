import XCTest
@testable import MaludexControlCenterCore

final class DoctorReportTests: XCTestCase {
    func testDecodesMobileHandoffReportAndBoundsPromptPreview() throws {
        let json = """
        {
          "file": "/Users/example/.codex-iphone-remote-bridge/mobile-handoff.jsonl",
          "entries": [
            {
              "schemaVersion": 1,
              "id": "handoff-1",
              "createdAt": "2026-05-05T01:02:03.000Z",
              "source": "iphone",
              "kind": "turn.start",
              "threadId": "thread-1234567890",
              "turnId": "turn-1",
              "cwd": "/Users/example/App",
              "model": "gpt-5.5",
              "prompt": "Please review the iPhone handoff inbox and summarize next steps for the desktop user.",
              "promptBytes": 83,
              "attachments": [
                {
                  "kind": "image",
                  "filename": "photo.png",
                  "mimeType": "image/png",
                  "bytes": 42
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(MobileHandoffReport.self, from: json)

        XCTAssertEqual(report.file, "/Users/example/.codex-iphone-remote-bridge/mobile-handoff.jsonl")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].kind, "turn.start")
        XCTAssertEqual(report.entries[0].attachments.first?.filename, "photo.png")
        XCTAssertEqual(report.entries[0].promptPreview(maxCharacters: 24).count, 27)
        XCTAssertTrue(report.entries[0].promptPreview(maxCharacters: 24).hasSuffix("..."))
        XCTAssertEqual(report.entries[0].shortThreadId, "thread-1...")
    }

    func testControlCenterCopyDefaultsToEnglishAndSupportsKorean() {
        XCTAssertEqual(ControlCenterLanguage.fallback, .english)
        XCTAssertEqual(ControlCenterCopy(language: .english).bridgeActionsTitle, "Bridge Actions")
        XCTAssertEqual(ControlCenterCopy(language: .korean).bridgeActionsTitle, "브릿지 작업")
        XCTAssertEqual(ControlCenterCopy(languageCode: "unknown").refreshButton, "Refresh")
        XCTAssertEqual(ControlCenterCopy(language: .korean).statusLabel(.healthy), "정상")
        XCTAssertEqual(ControlCenterCopy(language: .english).copyPromptButton, "Copy Prompt")
        XCTAssertEqual(ControlCenterCopy(language: .korean).expandPromptButton, "전체 보기")
        XCTAssertEqual(ControlCenterCopy(language: .korean).copyQRImageButton, "QR 이미지 복사")
        XCTAssertEqual(ControlCenterCopy(language: .english).nextStepTitle, "Recommended Next Step")
        XCTAssertEqual(ControlCenterCopy(language: .korean).recommendedActionTitle("repair"), "복구")
        XCTAssertEqual(ControlCenterCopy(language: .english).updateButton, "Update")
        XCTAssertEqual(ControlCenterCopy(language: .korean).recommendedActionTitle("update"), "업데이트")
    }

    func testDecodesHealthyDoctorReport() throws {
        let json = """
        {
          "status": "healthy",
          "repairable": false,
          "primaryAction": "none",
          "summary": "maludex bridge looks healthy.",
          "generatedAt": "2026-05-04T15:52:07.054Z",
          "repoRoot": "/Users/malulung/Documents/maludex",
          "packageVersion": "0.6.0",
          "launchAgent": {
            "exists": true,
            "plistPath": "/Users/malulung/Library/LaunchAgents/com.maludex.bridge.plist",
            "workingDirectory": "/Users/malulung/Documents/maludex",
            "programArguments": ["node", "dist/bridge/src/index.js"],
            "state": "running"
          },
          "tokenFile": {
            "path": "/Users/malulung/.codex-iphone-remote-bridge/token",
            "exists": true,
            "mode": "600",
            "isFile": true,
            "bytes": 44
          },
          "bridge": {
            "reachable": true,
            "host": "100.75.40.51",
            "port": 8765,
            "bridgeVersion": "0.6.0"
          },
          "issues": []
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(DoctorReport.self, from: json)

        XCTAssertEqual(report.status, .healthy)
        XCTAssertEqual(report.statusLabel, "Healthy")
        XCTAssertEqual(report.endpoint, "100.75.40.51:8765")
        XCTAssertEqual(report.launchAgent?.state, "running")
        XCTAssertEqual(report.tokenFile?.mode, "600")
    }

    func testDecodesRepairableErrorReport() throws {
        let json = """
        {
          "status": "error",
          "repairable": true,
          "primaryAction": "repair",
          "summary": "2 issues need attention.",
          "generatedAt": "2026-05-04T15:52:07.054Z",
          "repoRoot": "/Users/malulung/Documents/maludex",
          "packageVersion": "0.6.0",
          "bridge": {
            "reachable": false,
            "host": "100.75.40.51",
            "port": 8765,
            "error": "ECONNREFUSED"
          },
          "issues": [
            {
              "code": "launch_agent_repo_mismatch",
              "severity": "error",
              "title": "LaunchAgent points at a different repo path",
              "detail": "Expected current repo.",
              "repairable": true
            }
          ]
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(DoctorReport.self, from: json)

        XCTAssertEqual(report.status, .error)
        XCTAssertEqual(report.primaryAction, "repair")
        XCTAssertTrue(report.repairable)
        XCTAssertEqual(report.issues.first?.code, "launch_agent_repo_mismatch")
    }

    func testToolResolverFindsHomebrewNodeWhenAppPathDoesNotContainIt() {
        let resolved = ToolExecutableResolver.resolve(
            command: "node",
            environment: ["PATH": "/usr/bin:/bin"],
            fileExists: { $0 == "/opt/homebrew/bin/node" }
        )

        XCTAssertEqual(resolved.executable, "/opt/homebrew/bin/node")
        XCTAssertEqual(resolved.argumentsPrefix, [])
    }

    func testToolExecutionEnvironmentKeepsResolvedToolDirectoryOnPath() {
        let tool = ToolExecutable(executable: "/opt/homebrew/bin/node", argumentsPrefix: [])
        let environment = ToolExecutableResolver.executionEnvironment(
            for: tool,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/example"]
        )
        let pathItems = environment["PATH"]?.split(separator: ":").map(String.init) ?? []

        XCTAssertEqual(pathItems.first, "/opt/homebrew/bin")
        XCTAssertTrue(pathItems.contains("/usr/bin"))
        XCTAssertTrue(pathItems.contains("/bin"))
    }

    func testToolResolverFindsVoltaNodeBeforeShellFallback() {
        let resolved = ToolExecutableResolver.resolve(
            command: "node",
            environment: ["HOME": "/Users/example", "PATH": "/usr/bin:/bin"],
            fileExists: { $0 == "/Users/example/.volta/bin/node" || $0 == "/bin/zsh" }
        )

        XCTAssertEqual(resolved.executable, "/Users/example/.volta/bin/node")
        XCTAssertEqual(resolved.argumentsPrefix, [])
    }

    func testToolResolverUsesManagedShellFallbackForNvmWhenDirectNodeIsUnavailable() {
        let resolved = ToolExecutableResolver.resolve(
            command: "node",
            environment: ["HOME": "/Users/example", "PATH": "/usr/bin:/bin"],
            fileExists: { $0 == "/bin/zsh" }
        )

        XCTAssertEqual(resolved.executable, "/bin/zsh")
        XCTAssertEqual(Array(resolved.argumentsPrefix.prefix(2)), ["-lc", ToolExecutableResolver.managedShellBootstrap])
        XCTAssertEqual(Array(resolved.argumentsPrefix.suffix(2)), ["maludex-tool", "node"])
        XCTAssertTrue(ToolExecutableResolver.managedShellBootstrap.contains(".nvm/nvm.sh"))
    }

    func testToolResolverFallsBackToEnvWhenNoKnownPathExists() {
        let resolved = ToolExecutableResolver.resolve(
            command: "node",
            environment: ["PATH": "/usr/bin:/bin"],
            fileExists: { _ in false }
        )

        XCTAssertEqual(resolved.executable, "/usr/bin/env")
        XCTAssertEqual(resolved.argumentsPrefix, ["node"])
    }

    func testToolResolverPrefersExplicitOverride() {
        let resolved = ToolExecutableResolver.resolve(
            command: "npm",
            environment: ["MALUDEX_NPM_PATH": "/custom/bin/npm", "PATH": "/usr/bin:/bin"],
            fileExists: { $0 == "/custom/bin/npm" || $0 == "/opt/homebrew/bin/npm" }
        )

        XCTAssertEqual(resolved.executable, "/custom/bin/npm")
        XCTAssertEqual(resolved.argumentsPrefix, [])
    }

    func testDoctorRunnerExposesMobileHandoffCommand() {
        let runner = DoctorRunner(repoRoot: URL(fileURLWithPath: "/Users/example/maludex"))

        XCTAssertEqual(
            runner.mobileHandoffCommand(limit: 5),
            "node dist/bridge/src/mobile-handoff-cli.js --json --limit 5"
        )
    }

    func testDoctorRunnerExposesUpdateCommand() {
        let runner = DoctorRunner(repoRoot: URL(fileURLWithPath: "/Users/example/maludex"))

        XCTAssertEqual(
            runner.updateCommand,
            "git pull --ff-only && npm ci && npm run build && node dist/bridge/src/doctor-cli.js --restart --json"
        )
    }
}
