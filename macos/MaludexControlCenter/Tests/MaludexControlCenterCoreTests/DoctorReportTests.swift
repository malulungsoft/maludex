import XCTest
@testable import MaludexControlCenterCore

final class DoctorReportTests: XCTestCase {
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
}
