export type DoctorSeverity = "info" | "warning" | "error";
export type DoctorStatus = "healthy" | "warning" | "error";
export type DoctorPrimaryAction = "none" | "start" | "repair";

export type DoctorIssue = {
  code: string;
  severity: DoctorSeverity;
  title: string;
  detail: string;
  repairable: boolean;
};

export type LaunchAgentSnapshot = {
  exists: boolean;
  plistPath: string;
  workingDirectory?: string;
  programArguments?: string[];
  state?: string;
  lastExitCode?: string;
};

export type TokenFileSnapshot = {
  path: string;
  exists: boolean;
  mode?: string;
  isFile?: boolean;
  bytes?: number;
  preview?: string;
};

export type BridgeRuntimeSnapshot = {
  reachable: boolean;
  host?: string;
  port?: number;
  bridgeVersion?: string;
  error?: string;
};

export type DoctorSnapshot = {
  repoRoot: string;
  packageVersion: string;
  generatedAt?: string;
  launchAgent?: LaunchAgentSnapshot;
  tokenFile?: TokenFileSnapshot;
  bridge?: BridgeRuntimeSnapshot;
  tailscaleIp?: string;
};

export type DoctorReport = Required<Pick<DoctorSnapshot, "repoRoot" | "packageVersion">> & {
  status: DoctorStatus;
  repairable: boolean;
  primaryAction: DoctorPrimaryAction;
  summary: string;
  generatedAt: string;
  launchAgent?: LaunchAgentSnapshot;
  tokenFile?: TokenFileSnapshot;
  bridge?: BridgeRuntimeSnapshot;
  tailscaleIp?: string;
  issues: DoctorIssue[];
};

export type DoctorReadinessOptions<T> = {
  attempts?: number;
  delayMs?: number;
  isReady: (value: T) => boolean;
  sleep?: (delayMs: number) => Promise<void>;
};

export function launchAgentSnapshotFromPlist(plistPath: string, value: unknown): LaunchAgentSnapshot {
  if (!isRecord(value)) {
    return {
      exists: true,
      plistPath
    };
  }
  return {
    exists: true,
    plistPath,
    workingDirectory: typeof value.WorkingDirectory === "string" ? value.WorkingDirectory : undefined,
    programArguments: stringArray(value.ProgramArguments)
  };
}

export function analyzeDoctorSnapshot(snapshot: DoctorSnapshot): DoctorReport {
  const issues: DoctorIssue[] = [];
  const expectedEntrypoint = `${snapshot.repoRoot}/dist/bridge/src/index.js`;

  if (!snapshot.launchAgent?.exists) {
    issues.push({
      code: "launch_agent_missing",
      severity: "error",
      title: "LaunchAgent is not installed",
      detail: "maludex is not configured to start the Mac bridge in the background.",
      repairable: true
    });
  } else {
    if (snapshot.launchAgent.workingDirectory && snapshot.launchAgent.workingDirectory !== snapshot.repoRoot) {
      issues.push({
        code: "launch_agent_repo_mismatch",
        severity: "error",
        title: "LaunchAgent points at a different repo path",
        detail: `Expected ${snapshot.repoRoot}, but the LaunchAgent uses ${snapshot.launchAgent.workingDirectory}.`,
        repairable: true
      });
    }

    const entrypoint = bridgeEntrypoint(snapshot.launchAgent.programArguments);
    if (entrypoint && entrypoint !== expectedEntrypoint) {
      issues.push({
        code: "launch_agent_entrypoint_mismatch",
        severity: "error",
        title: "LaunchAgent starts an old bridge build",
        detail: `Expected ${expectedEntrypoint}, but the LaunchAgent starts ${entrypoint}.`,
        repairable: true
      });
    }

    const bindHost = bridgeBindHost(snapshot.launchAgent.programArguments);
    if (bindHost && isWildcardBindHost(bindHost)) {
      issues.push({
        code: "launch_agent_wildcard_host",
        severity: "error",
        title: "LaunchAgent uses an unsafe wildcard bridge host",
        detail: `The bridge refuses wildcard WebSocket binds such as ${bindHost}. Use 127.0.0.1, ::1, or a specific Tailscale IP instead.`,
        repairable: true
      });
    }
  }

  if (!snapshot.tokenFile?.exists) {
    issues.push({
      code: "token_file_missing",
      severity: "error",
      title: "Pairing token file is missing",
      detail: "The bridge requires a local capability token file before it can accept iPhone connections.",
      repairable: true
    });
  } else {
    if (snapshot.tokenFile.isFile === false) {
      issues.push({
        code: "token_file_not_regular",
        severity: "error",
        title: "Pairing token path is not a regular file",
        detail: `${snapshot.tokenFile.path} must be a regular 0600 file.`,
        repairable: false
      });
    }
    if (snapshot.tokenFile.mode !== "600") {
      issues.push({
        code: "token_file_permissions",
        severity: "error",
        title: "Pairing token permissions are too open",
        detail: `${snapshot.tokenFile.path} must use 0600 permissions.`,
        repairable: true
      });
    }
    if (typeof snapshot.tokenFile.bytes === "number" && snapshot.tokenFile.bytes < 32) {
      issues.push({
        code: "token_file_too_short",
        severity: "error",
        title: "Pairing token is too short",
        detail: `${snapshot.tokenFile.path} must contain at least 32 bytes of token material. Rotate the token before pairing an iPhone.`,
        repairable: true
      });
    }
  }

  if (snapshot.bridge) {
    if (!snapshot.bridge.reachable) {
      issues.push({
        code: "bridge_unreachable",
        severity: "error",
        title: "Bridge is not reachable",
        detail: snapshot.bridge.error ?? "The WebSocket bridge did not accept a local status connection.",
        repairable: true
      });
    } else if (snapshot.bridge.bridgeVersion && snapshot.bridge.bridgeVersion !== snapshot.packageVersion) {
      issues.push({
        code: "bridge_version_mismatch",
        severity: "warning",
        title: "Bridge version does not match the repo",
        detail: `The running bridge is ${snapshot.bridge.bridgeVersion}, but this repo is ${snapshot.packageVersion}.`,
        repairable: true
      });
    }
  }

  const status = statusForIssues(issues);
  const repairable = issues.some((issue) => issue.repairable);
  const primaryAction = primaryActionFor(status, repairable, snapshot.launchAgent);
  return {
    status,
    repairable,
    primaryAction,
    summary: summaryFor(status, issues),
    generatedAt: snapshot.generatedAt ?? new Date().toISOString(),
    repoRoot: snapshot.repoRoot,
    packageVersion: snapshot.packageVersion,
    launchAgent: snapshot.launchAgent,
    tokenFile: snapshot.tokenFile,
    bridge: snapshot.bridge,
    tailscaleIp: snapshot.tailscaleIp,
    issues
  };
}

export function redactedDoctorReport<T>(value: T): T {
  return redactValue(value) as T;
}

export async function waitForDoctorReadiness<T>(
  check: () => Promise<T>,
  options: DoctorReadinessOptions<T>
): Promise<T> {
  const attempts = Math.max(1, options.attempts ?? 8);
  const delayMs = Math.max(0, options.delayMs ?? 750);
  const sleep = options.sleep ?? sleepMs;
  let latest = await check();

  for (let attempt = 1; attempt < attempts && !options.isReady(latest); attempt += 1) {
    if (delayMs > 0) {
      await sleep(delayMs);
    }
    latest = await check();
  }

  return latest;
}

function bridgeEntrypoint(programArguments: string[] | undefined): string | null {
  if (!programArguments) {
    return null;
  }
  return programArguments.find((argument) => argument.endsWith("/dist/bridge/src/index.js")) ?? null;
}

function bridgeBindHost(programArguments: string[] | undefined): string | null {
  const hostIndex = programArguments?.indexOf("--host") ?? -1;
  if (hostIndex < 0) {
    return null;
  }
  return programArguments?.[hostIndex + 1] ?? null;
}

function isWildcardBindHost(host: string): boolean {
  return host === "0.0.0.0" || host === "::";
}

function statusForIssues(issues: DoctorIssue[]): DoctorStatus {
  if (issues.some((issue) => issue.severity === "error")) {
    return "error";
  }
  if (issues.some((issue) => issue.severity === "warning")) {
    return "warning";
  }
  return "healthy";
}

function primaryActionFor(
  status: DoctorStatus,
  repairable: boolean,
  launchAgent: LaunchAgentSnapshot | undefined
): DoctorPrimaryAction {
  if (status === "healthy") {
    return "none";
  }
  if (!launchAgent?.exists) {
    return "repair";
  }
  return repairable ? "repair" : "start";
}

function summaryFor(status: DoctorStatus, issues: DoctorIssue[]): string {
  if (status === "healthy") {
    return "maludex bridge looks healthy.";
  }
  if (issues.length === 1) {
    return issues[0].title;
  }
  return `${issues.length} issues need attention.`;
}

function redactValue(value: unknown, key = ""): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => redactValue(item));
  }
  if (value && typeof value === "object") {
    const redacted: Record<string, unknown> = {};
    for (const [entryKey, entryValue] of Object.entries(value)) {
      redacted[entryKey] = redactValue(entryValue, entryKey);
    }
    return redacted;
  }
  if (typeof value === "string") {
    if (isSecretKey(key)) {
      return "<redacted>";
    }
    return redactString(value);
  }
  return value;
}

function isSecretKey(key: string): boolean {
  return /^(authorization|token|preview|secret)$/i.test(key);
}

function redactString(value: string): string {
  return value.replace(/Bearer\s+[A-Za-z0-9._~+/-]+={0,2}/gi, "Bearer <redacted>");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) {
    return undefined;
  }
  const strings = value.filter((item): item is string => typeof item === "string");
  return strings.length > 0 ? strings : undefined;
}

function sleepMs(delayMs: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, delayMs);
  });
}
