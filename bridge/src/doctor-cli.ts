#!/usr/bin/env node
import QRCode from "qrcode";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, readFileSync, statSync } from "node:fs";
import { homedir, hostname } from "node:os";
import path from "node:path";
import WebSocket from "ws";
import { loadCapabilityTokenFromFile, rotateCapabilityTokenFile } from "./auth.js";
import {
  analyzeDoctorSnapshot,
  launchAgentSnapshotFromPlist,
  redactedDoctorReport,
  waitForDoctorReadiness,
  type BridgeRuntimeSnapshot,
  type DoctorReport,
  type DoctorSnapshot,
  type LaunchAgentSnapshot,
  type TokenFileSnapshot
} from "./doctor.js";

type DoctorCliOptions = {
  json: boolean;
  action: "status" | "repair" | "start" | "stop" | "restart" | "rotate-token" | "pairing-qr";
  label: string;
  repoRoot: string;
  tokenFile: string;
  plistPath: string;
  host?: string;
  port?: number;
  qrFile?: string;
  name: string;
};

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  if (options.action !== "status") {
    await performAction(options);
  }
  const snapshot = await collectDoctorSnapshotAfterAction(options);
  const report = analyzeDoctorSnapshot(snapshot);
  writeOutput(report, options.json);
}

async function performAction(options: DoctorCliOptions): Promise<void> {
  if (options.action === "repair") {
    const snapshot = await collectDoctorSnapshot(options);
    const host = options.host ?? snapshot.bridge?.host ?? snapshot.tailscaleIp ?? "127.0.0.1";
    const port = options.port ?? snapshot.bridge?.port ?? 8765;
    execFileSync(path.join(options.repoRoot, "scripts", "install-launch-agent.sh"), {
      cwd: options.repoRoot,
      env: {
        ...process.env,
        BRIDGE_HOST: host,
        BRIDGE_PORT: String(port),
        BRIDGE_TOKEN_FILE: options.tokenFile,
        BRIDGE_LAUNCH_AGENT: options.plistPath,
        BRIDGE_LABEL: options.label
      },
      stdio: options.json ? "pipe" : "inherit"
    });
    return;
  }

  if (options.action === "restart") {
    launchctl(["kickstart", "-k", launchctlService(options.label)]);
    return;
  }

  if (options.action === "start") {
    if (existsSync(options.plistPath)) {
      try {
        launchctl(["bootstrap", launchctlDomain(), options.plistPath]);
      } catch {
        launchctl(["kickstart", "-k", launchctlService(options.label)]);
      }
    }
    return;
  }

  if (options.action === "stop") {
    launchctl(["bootout", launchctlService(options.label)], true);
    return;
  }

  if (options.action === "rotate-token") {
    await rotateCapabilityTokenFile(options.tokenFile);
    launchctl(["kickstart", "-k", launchctlService(options.label)], true);
    if (options.qrFile) {
      await writePairingQr(options);
    }
    return;
  }

  if (options.action === "pairing-qr") {
    await writePairingQr(options);
  }
}

async function collectDoctorSnapshot(options: DoctorCliOptions): Promise<DoctorSnapshot> {
  const packageVersion = packageVersionFor(options.repoRoot);
  const launchAgent = launchAgentSnapshot(options);
  const tokenFile = tokenFileSnapshot(options.tokenFile);
  const tailscaleIp = firstTailscaleIp();
  const bridgeTarget = bridgeTargetFrom(options, launchAgent, tailscaleIp);
  const bridge = await bridgeRuntimeSnapshot(bridgeTarget.host, bridgeTarget.port, tokenFile);

  return {
    repoRoot: options.repoRoot,
    packageVersion,
    launchAgent,
    tokenFile,
    bridge,
    tailscaleIp
  };
}

async function collectDoctorSnapshotAfterAction(options: DoctorCliOptions): Promise<DoctorSnapshot> {
  if (!shouldWaitForBridgeReadiness(options.action)) {
    return collectDoctorSnapshot(options);
  }

  return waitForDoctorReadiness(
    () => collectDoctorSnapshot(options),
    {
      attempts: 10,
      delayMs: 750,
      isReady: (snapshot) => snapshot.bridge?.reachable === true
    }
  );
}

function shouldWaitForBridgeReadiness(action: DoctorCliOptions["action"]): boolean {
  return action === "repair" || action === "start" || action === "restart" || action === "rotate-token";
}

function launchAgentSnapshot(options: DoctorCliOptions): LaunchAgentSnapshot {
  if (!existsSync(options.plistPath)) {
    return {
      exists: false,
      plistPath: options.plistPath
    };
  }

  let snapshot = launchAgentSnapshotFromPlist(options.plistPath, parsePlistJson(options.plistPath));
  const state = launchctlState(options.label);
  snapshot = {
    ...snapshot,
    state: state.state,
    lastExitCode: state.lastExitCode
  };
  return snapshot;
}

function tokenFileSnapshot(tokenFile: string): TokenFileSnapshot {
  if (!existsSync(tokenFile)) {
    return {
      path: tokenFile,
      exists: false
    };
  }
  const stat = statSync(tokenFile);
  return {
    path: tokenFile,
    exists: true,
    mode: (stat.mode & 0o777).toString(8),
    isFile: stat.isFile(),
    bytes: stat.size
  };
}

async function bridgeRuntimeSnapshot(
  host: string | undefined,
  port: number | undefined,
  tokenFile: TokenFileSnapshot
): Promise<BridgeRuntimeSnapshot | undefined> {
  if (!host || !port) {
    return undefined;
  }
  if (!tokenFile.exists || tokenFile.mode !== "600" || tokenFile.isFile === false) {
    return {
      reachable: false,
      host,
      port,
      error: "Token file is not ready for authenticated bridge status checks."
    };
  }

  try {
    const token = loadCapabilityTokenFromFile(tokenFile.path);
    const status = await requestBridgeStatus(host, port, token);
    const bridgeVersion = record(status.result).bridgeVersion;
    return {
      reachable: Boolean(status.ok),
      host,
      port,
      bridgeVersion: typeof bridgeVersion === "string" ? bridgeVersion : undefined,
      error: status.ok ? undefined : "Bridge rejected the status request."
    };
  } catch (error) {
    return {
      reachable: false,
      host,
      port,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

function requestBridgeStatus(host: string, port: number, token: string): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://${host}:${port}`, {
      headers: {
        Authorization: `Bearer ${token}`
      }
    });
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error("Bridge status check timed out."));
    }, 6000);

    ws.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    ws.on("message", (data) => {
      const message = JSON.parse(String(data)) as Record<string, unknown>;
      if (message.type === "bridge.ready") {
        ws.send(JSON.stringify({ id: "doctor-status", type: "bridge.status" }));
      } else if (message.id === "doctor-status") {
        clearTimeout(timeout);
        ws.close();
        resolve(message);
      }
    });
  });
}

async function writePairingQr(options: DoctorCliOptions): Promise<void> {
  const snapshot = await collectDoctorSnapshot(options);
  const host = options.host ?? snapshot.bridge?.host ?? snapshot.tailscaleIp ?? "127.0.0.1";
  const port = options.port ?? snapshot.bridge?.port ?? 8765;
  const token = loadCapabilityTokenFromFile(options.tokenFile);
  const query = new URLSearchParams({
    host,
    port: String(port),
    token,
    tls: "0",
    name: options.name
  });
  const qrFile = options.qrFile ?? "/tmp/maludex-pairing.png";
  await QRCode.toFile(qrFile, `maludex://pair?${query.toString()}`, {
    type: "png",
    margin: 2,
    scale: 8
  });
  chmodSync(qrFile, 0o600);
}

function bridgeTargetFrom(
  options: DoctorCliOptions,
  launchAgent: LaunchAgentSnapshot | undefined,
  tailscaleIp: string | undefined
): { host: string; port: number } {
  const args = launchAgent?.programArguments ?? [];
  return {
    host: options.host ?? valueAfter(args, "--host") ?? tailscaleIp ?? "127.0.0.1",
    port: options.port ?? numberValue(valueAfter(args, "--port")) ?? 8765
  };
}

function parsePlistJson(plistPath: string): unknown {
  const output = execFileSync("plutil", ["-convert", "json", "-o", "-", plistPath], { encoding: "utf8" });
  return JSON.parse(output) as unknown;
}

function launchctlState(label: string): { state?: string; lastExitCode?: string } {
  try {
    const output = execFileSync("launchctl", ["print", launchctlService(label)], { encoding: "utf8" });
    return {
      state: firstMatch(output, /^\s*state = (.+)$/m),
      lastExitCode: firstMatch(output, /^\s*last exit code = (.+)$/m)
    };
  } catch {
    return {};
  }
}

function launchctl(args: string[], allowFailure = false): void {
  try {
    execFileSync("launchctl", args, { stdio: "pipe" });
  } catch (error) {
    if (!allowFailure) {
      throw error;
    }
  }
}

function firstTailscaleIp(): string | undefined {
  try {
    const output = execFileSync("tailscale", ["ip", "-4"], { encoding: "utf8" });
    return output.split(/\r?\n/).find((line) => /^100\.(6[4-9]|[789]\d|1[01]\d|12[0-7])\./.test(line));
  } catch {
    return undefined;
  }
}

function packageVersionFor(repoRoot: string): string {
  const packageJson = JSON.parse(readFileSync(path.join(repoRoot, "package.json"), "utf8")) as Record<string, unknown>;
  return typeof packageJson.version === "string" ? packageJson.version : "0.0.0";
}

function parseArgs(args: string[]): DoctorCliOptions {
  const repoRoot = process.env.MALUDEX_REPO_ROOT ?? process.cwd();
  const options: DoctorCliOptions = {
    json: false,
    action: "status",
    label: process.env.BRIDGE_LABEL ?? "com.maludex.bridge",
    repoRoot,
    tokenFile: process.env.BRIDGE_TOKEN_FILE ?? path.join(homedir(), ".codex-iphone-remote-bridge", "token"),
    plistPath: process.env.BRIDGE_LAUNCH_AGENT ?? path.join(homedir(), "Library", "LaunchAgents", "com.maludex.bridge.plist"),
    name: process.env.BRIDGE_NAME ?? hostname()
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--json") {
      options.json = true;
    } else if (arg === "--repair") {
      options.action = "repair";
    } else if (arg === "--start") {
      options.action = "start";
    } else if (arg === "--stop") {
      options.action = "stop";
    } else if (arg === "--restart") {
      options.action = "restart";
    } else if (arg === "--rotate-token") {
      options.action = "rotate-token";
    } else if (arg === "--pairing-qr") {
      options.action = "pairing-qr";
    } else if (arg === "--repo-root") {
      options.repoRoot = requiredValue(args, ++index, "--repo-root");
    } else if (arg === "--host") {
      options.host = requiredValue(args, ++index, "--host");
    } else if (arg === "--port") {
      options.port = numberValue(requiredValue(args, ++index, "--port"));
    } else if (arg === "--token-file") {
      options.tokenFile = requiredValue(args, ++index, "--token-file");
    } else if (arg === "--plist") {
      options.plistPath = requiredValue(args, ++index, "--plist");
    } else if (arg === "--qr-file") {
      options.qrFile = requiredValue(args, ++index, "--qr-file");
    } else if (arg === "--name") {
      options.name = requiredValue(args, ++index, "--name");
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  options.repoRoot = path.resolve(options.repoRoot);
  return options;
}

function writeOutput(report: DoctorReport, json: boolean): void {
  const redacted = redactedDoctorReport(report);
  if (json) {
    process.stdout.write(`${JSON.stringify(redacted, null, 2)}\n`);
    return;
  }
  process.stdout.write(`maludex bridge: ${redacted.status}\n`);
  process.stdout.write(`${redacted.summary}\n`);
  for (const issue of redacted.issues) {
    process.stdout.write(`- [${issue.severity}] ${issue.title}: ${issue.detail}\n`);
  }
}

function launchctlDomain(): string {
  return `gui/${process.getuid?.() ?? 501}`;
}

function launchctlService(label: string): string {
  return `${launchctlDomain()}/${label}`;
}

function valueAfter(args: string[], flag: string): string | undefined {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
}

function numberValue(value: string | undefined): number | undefined {
  if (!value) {
    return undefined;
  }
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 && parsed <= 65535 ? parsed : undefined;
}

function firstMatch(value: string, pattern: RegExp): string | undefined {
  return pattern.exec(value)?.[1];
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function requiredValue(args: string[], index: number, flag: string): string {
  const value = args[index];
  if (!value) {
    throw new Error(`${flag} requires a value.`);
  }
  return value;
}

function printHelp(): void {
  process.stdout.write(`maludex doctor

Usage:
  npm run doctor -- [--json]
  npm run doctor -- --repair
  npm run doctor -- --restart

Options:
  --json              Print redacted JSON for the macOS app.
  --repair            Reinstall the LaunchAgent from the current repo path.
  --start             Start the LaunchAgent.
  --stop              Stop the LaunchAgent.
  --restart           Restart the LaunchAgent.
  --rotate-token      Rotate the pairing token and restart the bridge.
  --pairing-qr        Write a pairing QR image.
  --qr-file <path>    QR file path. Defaults to /tmp/maludex-pairing.png.
  --host <host>       Override bridge host for checks and QR generation.
  --port <port>       Override bridge port for checks and QR generation.
`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`doctor failed: ${message}\n`);
  process.exit(1);
});
