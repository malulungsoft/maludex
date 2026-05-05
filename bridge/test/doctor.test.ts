import { describe, expect, test } from "vitest";

import {
  analyzeDoctorSnapshot,
  launchAgentSnapshotFromPlist,
  redactedDoctorReport,
  waitForDoctorReadiness
} from "../src/doctor.js";

describe("analyzeDoctorSnapshot", () => {
  test("marks a LaunchAgent that still points at an old repo path as repairable", () => {
    const report = analyzeDoctorSnapshot({
      repoRoot: "/Users/malulung/Documents/maludex",
      packageVersion: "0.6.0",
      launchAgent: {
        exists: true,
        plistPath: "/Users/malulung/Library/LaunchAgents/com.maludex.bridge.plist",
        workingDirectory: "/Users/malulung/Documents/New project",
        programArguments: [
          "/opt/homebrew/bin/node",
          "/Users/malulung/Documents/New project/dist/bridge/src/index.js",
          "--host",
          "100.75.40.51",
          "--port",
          "8765",
          "--no-qr"
        ],
        state: "spawn scheduled",
        lastExitCode: "78: EX_CONFIG"
      },
      tokenFile: {
        path: "/Users/malulung/.codex-iphone-remote-bridge/token",
        exists: true,
        mode: "600",
        isFile: true,
        bytes: 44
      },
      bridge: {
        reachable: false,
        host: "100.75.40.51",
        port: 8765,
        error: "ECONNREFUSED"
      }
    });

    expect(report.status).toBe("error");
    expect(report.repairable).toBe(true);
    expect(report.primaryAction).toBe("repair");
    expect(report.issues).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: "launch_agent_repo_mismatch",
          severity: "error",
          repairable: true
        }),
        expect.objectContaining({
          code: "bridge_unreachable",
          severity: "error"
        })
      ])
    );
  });

  test("reports a healthy LaunchAgent and matching bridge version", () => {
    const report = analyzeDoctorSnapshot({
      repoRoot: "/Users/malulung/Documents/maludex",
      packageVersion: "0.6.0",
      launchAgent: {
        exists: true,
        plistPath: "/Users/malulung/Library/LaunchAgents/com.maludex.bridge.plist",
        workingDirectory: "/Users/malulung/Documents/maludex",
        programArguments: [
          "/opt/homebrew/bin/node",
          "/Users/malulung/Documents/maludex/dist/bridge/src/index.js",
          "--host",
          "100.75.40.51",
          "--port",
          "8765",
          "--no-qr"
        ],
        state: "running"
      },
      tokenFile: {
        path: "/Users/malulung/.codex-iphone-remote-bridge/token",
        exists: true,
        mode: "600",
        isFile: true,
        bytes: 44
      },
      bridge: {
        reachable: true,
        host: "100.75.40.51",
        port: 8765,
        bridgeVersion: "0.6.0"
      }
    });

    expect(report.status).toBe("healthy");
    expect(report.primaryAction).toBe("none");
    expect(report.issues).toHaveLength(0);
  });

  test("recommends update when the running bridge version is behind the repo", () => {
    const report = analyzeDoctorSnapshot({
      repoRoot: "/Users/malulung/Documents/maludex",
      packageVersion: "0.8.0",
      launchAgent: {
        exists: true,
        plistPath: "/Users/malulung/Library/LaunchAgents/com.maludex.bridge.plist",
        workingDirectory: "/Users/malulung/Documents/maludex",
        programArguments: ["/opt/homebrew/bin/node", "/Users/malulung/Documents/maludex/dist/bridge/src/index.js"],
        state: "running"
      },
      bridge: {
        reachable: true,
        host: "127.0.0.1",
        port: 8765,
        bridgeVersion: "0.7.5"
      }
    });

    expect(report.issues.map((issue) => issue.code)).toContain("bridge_version_mismatch");
    expect(report.primaryAction).toBe("update");
  });

  test("marks a LaunchAgent wildcard host as repairable before the bridge starts", () => {
    const report = analyzeDoctorSnapshot({
      repoRoot: "/Users/malulung/Documents/maludex",
      packageVersion: "0.6.13",
      launchAgent: {
        exists: true,
        plistPath: "/Users/malulung/Library/LaunchAgents/com.maludex.bridge.plist",
        workingDirectory: "/Users/malulung/Documents/maludex",
        programArguments: [
          "/opt/homebrew/bin/node",
          "/Users/malulung/Documents/maludex/dist/bridge/src/index.js",
          "--host",
          "0.0.0.0",
          "--port",
          "8765",
          "--no-qr"
        ],
        state: "spawn scheduled"
      },
      tokenFile: {
        path: "/Users/malulung/.codex-iphone-remote-bridge/token",
        exists: true,
        mode: "600",
        isFile: true,
        bytes: 44
      }
    });

    expect(report.status).toBe("error");
    expect(report.primaryAction).toBe("repair");
    expect(report.issues).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: "launch_agent_wildcard_host",
          severity: "error",
          repairable: true
        })
      ])
    );
  });

  test("marks a short pairing token as repairable before status checks", () => {
    const report = analyzeDoctorSnapshot({
      repoRoot: "/Users/malulung/Documents/maludex",
      packageVersion: "0.6.15",
      launchAgent: {
        exists: true,
        plistPath: "/Users/malulung/Library/LaunchAgents/com.maludex.bridge.plist",
        workingDirectory: "/Users/malulung/Documents/maludex",
        programArguments: [
          "/opt/homebrew/bin/node",
          "/Users/malulung/Documents/maludex/dist/bridge/src/index.js",
          "--host",
          "100.75.40.51",
          "--port",
          "8765",
          "--no-qr"
        ],
        state: "running"
      },
      tokenFile: {
        path: "/Users/malulung/.codex-iphone-remote-bridge/token",
        exists: true,
        mode: "600",
        isFile: true,
        bytes: 12
      }
    });

    expect(report.status).toBe("error");
    expect(report.primaryAction).toBe("repair");
    expect(report.issues).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: "token_file_too_short",
          severity: "error",
          repairable: true
        })
      ])
    );
  });

  test("redacts token-like values from copied diagnostics", () => {
    const report = redactedDoctorReport({
      status: "error",
      repairable: true,
      primaryAction: "repair",
      summary: "Bridge needs repair.",
      generatedAt: "2026-05-05T00:00:00.000Z",
      repoRoot: "/Users/malulung/Documents/maludex",
      packageVersion: "0.6.0",
      launchAgent: {
        exists: true,
        plistPath: "/Users/malulung/Library/LaunchAgents/com.maludex.bridge.plist",
        workingDirectory: "/Users/malulung/Documents/maludex",
        programArguments: ["node", "dist/bridge/src/index.js"]
      },
      tokenFile: {
        path: "/Users/malulung/.codex-iphone-remote-bridge/token",
        exists: true,
        mode: "600",
        isFile: true,
        bytes: 44,
        preview: "secret-token-that-must-never-leak"
      },
      bridge: {
        reachable: false,
        host: "100.75.40.51",
        port: 8765,
        error: "Authorization: Bearer secret-token-that-must-never-leak"
      },
      issues: []
    });

    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain("secret-token-that-must-never-leak");
    expect(serialized).toContain("<redacted>");
  });

  test("normalizes a LaunchAgent plist into a snapshot", () => {
    expect(launchAgentSnapshotFromPlist("/tmp/com.maludex.bridge.plist", {
      WorkingDirectory: "/Users/malulung/Documents/maludex",
      ProgramArguments: [
        "/opt/homebrew/bin/node",
        "/Users/malulung/Documents/maludex/dist/bridge/src/index.js",
        "--host",
        "100.75.40.51",
        "--port",
        "8765",
        "--no-qr"
      ]
    })).toEqual({
      exists: true,
      plistPath: "/tmp/com.maludex.bridge.plist",
      workingDirectory: "/Users/malulung/Documents/maludex",
      programArguments: [
        "/opt/homebrew/bin/node",
        "/Users/malulung/Documents/maludex/dist/bridge/src/index.js",
        "--host",
        "100.75.40.51",
        "--port",
        "8765",
        "--no-qr"
      ]
    });
  });
});

describe("waitForDoctorReadiness", () => {
  test("keeps polling until the bridge becomes reachable", async () => {
    let attempts = 0;
    const result = await waitForDoctorReadiness(
      async () => {
        attempts += 1;
        return {
          bridge: {
            reachable: attempts === 3
          }
        };
      },
      {
        attempts: 5,
        delayMs: 0,
        isReady: (snapshot) => snapshot.bridge.reachable
      }
    );

    expect(attempts).toBe(3);
    expect(result.bridge.reachable).toBe(true);
  });
});
