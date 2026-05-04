import { randomBytes } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { afterEach, expect, test } from "vitest";

import { BridgeServer } from "../src/bridge-server.js";
import { createLogger } from "../src/logger.js";
import { QueuedWebSocketSender } from "../src/queued-websocket-sender.js";
import { rotateCapabilityTokenFile } from "../src/auth.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.join(__dirname, "fixtures", "mock-codex-app-server.mjs");

const servers: BridgeServer[] = [];
const inboxes = new WeakMap<WebSocket, Array<Record<string, unknown>>>();

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.stop()));
});

function connect(url: string, token?: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, {
      headers: token ? { Authorization: `Bearer ${token}` } : {}
    });
    const inbox: Array<Record<string, unknown>> = [];
    inboxes.set(ws, inbox);
    ws.on("message", (data) => {
      inbox.push(JSON.parse(data.toString()));
    });
    ws.once("open", () => resolve(ws));
    ws.once("error", reject);
    ws.once("unexpected-response", (_request, response) => {
      reject(new Error(`unexpected response ${response.statusCode}`));
    });
  });
}

function waitForMessage<T extends Record<string, unknown>>(
  ws: WebSocket,
  predicate: (message: T) => boolean,
  timeoutMs = 5000
): Promise<T> {
  return new Promise((resolve, reject) => {
    const inbox = inboxes.get(ws) ?? [];
    const existingIndex = inbox.findIndex((message) => predicate(message as T));
    if (existingIndex >= 0) {
      const [message] = inbox.splice(existingIndex, 1);
      resolve(message as T);
      return;
    }

    const timeout = setTimeout(() => {
      ws.off("message", onMessage);
      reject(new Error("timed out waiting for websocket message"));
    }, timeoutMs);

    function onMessage(data: WebSocket.RawData) {
      const message = JSON.parse(data.toString()) as T;
      if (!predicate(message)) {
        return;
      }
      clearTimeout(timeout);
      ws.off("message", onMessage);
      resolve(message);
    }

    ws.on("message", onMessage);
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function closeSocket(ws: WebSocket): Promise<void> {
  return new Promise((resolve) => {
    if (ws.readyState === WebSocket.CLOSED) {
      resolve();
      return;
    }
    ws.once("close", () => resolve());
    ws.close();
  });
}

async function readReport(file: string): Promise<Array<{ message: Record<string, unknown> }>> {
  const content = await readFile(file, "utf8");
  return content
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

async function waitForReport(
  file: string,
  predicate: (entry: { message: Record<string, unknown> }) => boolean,
  timeoutMs = 5000
): Promise<{ message: Record<string, unknown> }> {
  const start = Date.now();
  let last: Array<{ message: Record<string, unknown> }> = [];
  while (Date.now() - start < timeoutMs) {
    try {
      last = await readReport(file);
      const match = last.find(predicate);
      if (match) {
        return match;
      }
    } catch {
      // Report file may not exist yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for report entry; saw ${last.length} entries`);
}

async function writeTokenFile(directory: string, token: string, mode: number): Promise<string> {
  const tokenFile = path.join(directory, "bridge-token");
  await writeFile(tokenFile, `${token}\n`, { mode });
  await chmod(tokenFile, mode);
  return tokenFile;
}

test("rejects token files that are not readable only by the owner", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o644);

  expect(
    () =>
      new BridgeServer({
        host: "127.0.0.1",
        port: 0,
        tokenFile,
        codexCommand: process.execPath,
        codexArgs: [fixturePath],
        logger: createLogger({ sink: () => undefined })
      })
  ).toThrow(/0600/);

  await rm(temp, { recursive: true, force: true });
});

test("rotating the token file invalidates old websocket credentials without restarting", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const wsUrl = `ws://${address.host}:${address.port}`;
  const ws = await connect(wsUrl, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    ws.once("close", (code, reason) => {
      resolve({ code, reason: reason.toString() });
    });
  });
  const rotated = await rotateCapabilityTokenFile(tokenFile);
  expect(rotated).not.toBe(token);
  await expect(connect(wsUrl, token)).rejects.toThrow(/unexpected response 401/);

  const newWs = await connect(wsUrl, rotated);
  await waitForMessage(newWs, (message) => message.type === "bridge.ready");
  await expect(closed).resolves.toMatchObject({ code: 4001 });

  ws.close();
  newWs.close();
  await rm(temp, { recursive: true, force: true });
});

test("reports bridge diagnostics without prompt bodies or bearer tokens", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    projectRoots: [temp],
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "mobile-status", type: "bridge.status" }));
  const response = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-status");

  expect(response).toMatchObject({
    type: "response",
    ok: true,
    result: {
      bridgeVersion: "0.6.6",
      protocolVersion: 1,
      host: "127.0.0.1",
      port: address.port,
      tokenFileValid: true,
      codexRunning: true,
      connectedClient: true,
      activeTurnCount: 0,
      pendingApprovalCount: 0,
      projectRootCount: 1
    }
  });
  expect(JSON.stringify(response)).not.toContain(token);

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("reports token-free active turn and approval diagnostics", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);
  const prompt = "SECRET diagnostic prompt body";

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    projectRoots: [temp],
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "mobile-thread", type: "thread.start", cwd: temp }));
  await waitForMessage(ws, (message) => message.id === "mobile-thread");

  ws.send(JSON.stringify({ id: "mobile-turn", type: "turn.start", threadId: "thread-1", prompt }));
  await waitForMessage(ws, (message) => message.id === "mobile-turn");
  await waitForMessage(ws, (message) => message.type === "approval.requested");

  ws.send(JSON.stringify({ id: "mobile-status-details", type: "bridge.status" }));
  const response = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-status-details");
  expect(response).toMatchObject({
    type: "response",
    ok: true,
    result: {
      activeTurns: [{ threadId: "thread-1", turnId: "turn-1" }],
      pendingApprovals: [
        {
          approvalId: "approval-1",
          method: "item/commandExecution/requestApproval"
        }
      ]
    }
  });
  expect(JSON.stringify(response)).not.toContain(token);
  expect(JSON.stringify(response)).not.toContain(prompt);

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("bridges authenticated iPhone messages to codex stdio JSONL and approval responses", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);
  const logs: string[] = [];

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: { MOCK_CODEX_REPORT_FILE: reportFile },
    logger: createLogger({
      sink: (entry) => logs.push(JSON.stringify(entry))
    })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const wsUrl = `ws://${address.host}:${address.port}`;

  await expect(connect(wsUrl)).rejects.toThrow(/unexpected response 401/);

  const ws = await connect(wsUrl, token);
  const ready = await waitForMessage(ws, (message) => message.type === "bridge.ready");
  expect(ready).toMatchObject({
    lastEventId: 0,
    protocolVersion: 1,
    minClientProtocolVersion: 1,
    bridgeVersion: "0.6.6"
  });

  ws.send(
    JSON.stringify({
      id: "mobile-1",
      type: "thread.start",
      cwd: temp
    })
  );
  const threadStarted = await waitForMessage(ws, (message) => message.id === "mobile-1");
  expect(threadStarted).toMatchObject({
    type: "response",
    ok: true,
    result: { thread: { id: "thread-1" } }
  });

  const prompt = "SECRET PROMPT BODY should not appear in bridge logs";
  ws.send(
    JSON.stringify({
      id: "mobile-2",
      type: "turn.start",
      threadId: "thread-1",
      prompt
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-2");
  const streamedEvent = await waitForMessage<Record<string, unknown> & { eventId: number }>(
    ws,
    (message) => message.type === "codex.event" && message.method === "item/agentMessage/delta"
  );
  expect(streamedEvent.eventId).toBeGreaterThan(0);
  const approval = await waitForMessage<Record<string, unknown> & { approvalId: string }>(
    ws,
    (message) => message.type === "approval.requested"
  );
  expect(approval).toMatchObject({
    type: "approval.requested",
    approvalId: "approval-1",
    method: "item/commandExecution/requestApproval",
    eventId: streamedEvent.eventId + 1
  });

  ws.close();
  const replayWs = await connect(`${wsUrl}?afterEventId=0`, token);
  await waitForMessage(replayWs, (message) => message.type === "bridge.ready");
  const replayedEvent = await waitForMessage<Record<string, unknown> & { eventId: number }>(
    replayWs,
    (message) => message.type === "codex.event" && message.eventId === streamedEvent.eventId
  );
  expect(replayedEvent).toMatchObject({
    type: "codex.event",
    method: "item/agentMessage/delta",
    replayed: true
  });

  replayWs.send(
    JSON.stringify({
      id: "mobile-3",
      type: "approval.respond",
      approvalId: approval.approvalId,
      decision: "accept"
    })
  );
  await waitForMessage(replayWs, (message) => message.id === "mobile-3" && message.ok === true);

  replayWs.send(
    JSON.stringify({
      id: "mobile-4",
      type: "turn.stop",
      threadId: "thread-1"
    })
  );
  await waitForMessage(replayWs, (message) => message.id === "mobile-4" && message.ok === true);

  const report = await readReport(reportFile);
  const initialize = report.find((entry) => entry.message.method === "initialize")?.message;
  const threadStart = report.find((entry) => entry.message.method === "thread/start")?.message;
  const turnStart = report.find((entry) => entry.message.method === "turn/start")?.message;
  const approvalResponse = report.find((entry) => entry.message.id === "approval-1")?.message;
  const interrupt = report.find((entry) => entry.message.method === "turn/interrupt")?.message;

  expect(initialize).toMatchObject({
    method: "initialize",
    params: {
      clientInfo: {
        name: "maludex-bridge"
      },
      capabilities: {
        experimentalApi: true
      }
    }
  });
  expect(threadStart).toMatchObject({
    method: "thread/start",
    params: {
      cwd: temp,
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandbox: "read-only",
      experimentalRawEvents: false,
      persistExtendedHistory: true
    }
  });
  expect(turnStart).toMatchObject({
    method: "turn/start",
    params: {
      threadId: "thread-1",
      approvalPolicy: "on-request",
      input: [{ type: "text", text: prompt, text_elements: [] }]
    }
  });
  expect(approvalResponse).toMatchObject({
    id: "approval-1",
    result: { decision: "accept" }
  });
  expect(interrupt).toMatchObject({
    method: "turn/interrupt",
    params: { threadId: "thread-1", turnId: "turn-1" }
  });
  expect(logs.join("\n")).not.toContain(prompt);

  replayWs.close();
  await rm(temp, { recursive: true, force: true });
});

test("keeps approval requests pending while the iPhone reconnects", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_DELAY_APPROVAL_MS: "75"
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const wsUrl = `ws://${address.host}:${address.port}`;
  const ws = await connect(wsUrl, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-offline-thread",
      type: "thread.start",
      cwd: temp
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-offline-thread");

  ws.send(
    JSON.stringify({
      id: "mobile-offline-turn",
      type: "turn.start",
      threadId: "thread-1",
      prompt: "trigger approval while phone is away"
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-offline-turn");
  await closeSocket(ws);
  await sleep(150);

  const replayWs = await connect(`${wsUrl}?afterEventId=0`, token);
  await waitForMessage(replayWs, (message) => message.type === "bridge.ready");
  const replayedApproval = await waitForMessage<Record<string, unknown> & { approvalId: string }>(
    replayWs,
    (message) => message.type === "approval.requested" && message.replayed === true,
    1000
  );
  expect(replayedApproval).toMatchObject({
    approvalId: "approval-1",
    method: "item/commandExecution/requestApproval"
  });

  replayWs.send(
    JSON.stringify({
      id: "mobile-offline-approval",
      type: "approval.respond",
      approvalId: replayedApproval.approvalId,
      decision: "accept"
    })
  );
  await waitForMessage(replayWs, (message) => message.id === "mobile-offline-approval" && message.ok === true);
  await waitForMessage(
    replayWs,
    (message) => message.type === "codex.event" && message.method === "serverRequest/resolved"
  );

  const report = await readReport(reportFile);
  const approvalResponse = report.find((entry) => entry.message.id === "approval-1")?.message;
  expect(approvalResponse).toMatchObject({
    id: "approval-1",
    result: { decision: "accept" }
  });

  replayWs.close();
  await rm(temp, { recursive: true, force: true });
});

test("lists bounded projects, creates a selected project, and forwards model choices", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const projectRoot = path.join(temp, "projects");
  const existingProject = path.join(projectRoot, "Existing App");
  const recentProject = path.join(projectRoot, "Recent Codex App");
  await mkdir(existingProject, { recursive: true });
  await mkdir(recentProject, { recursive: true });
  await writeFile(path.join(existingProject, "package.json"), "{}\n");

  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);
  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: recentProject
    },
    projectRoots: [projectRoot],
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "mobile-projects", type: "project.list" }));
  const projectList = await waitForMessage<Record<string, unknown>>(
    ws,
    (message) => message.id === "mobile-projects"
  );
  expect(projectList).toMatchObject({
    type: "response",
    ok: true,
    result: {
      roots: [{ path: projectRoot }],
      projects: expect.arrayContaining([
        expect.objectContaining({ path: existingProject, name: "Existing App", source: "scan" }),
        expect.objectContaining({ path: recentProject, name: "Recent Codex App", source: "recent" })
      ])
    }
  });

  ws.send(
    JSON.stringify({
      id: "mobile-create-project",
      type: "project.create",
      root: projectRoot,
      name: "Created From iPhone"
    })
  );
  const created = await waitForMessage<Record<string, unknown>>(
    ws,
    (message) => message.id === "mobile-create-project"
  );
  expect(created).toMatchObject({
    type: "response",
    ok: true,
    result: {
      project: {
        path: path.join(projectRoot, "Created From iPhone"),
        name: "Created From iPhone",
        source: "created"
      }
    }
  });

  ws.send(JSON.stringify({ id: "mobile-models", type: "model.list" }));
  const models = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-models");
  expect(models).toMatchObject({
    type: "response",
    ok: true,
    result: {
      data: expect.arrayContaining([
        expect.objectContaining({ model: "gpt-5.5", displayName: "GPT-5.5", inputModalities: ["text", "image"] })
      ])
    }
  });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("forwards safe intelligence, permission, and compaction controls", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: { MOCK_CODEX_REPORT_FILE: reportFile },
    projectRoots: [temp],
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-smart-thread",
      type: "thread.start",
      cwd: temp,
      model: "gpt-5.5",
      approvalPolicy: "on-failure",
      sandbox: "workspace-write",
      reasoningEffort: "high",
      reasoningSummary: "auto",
      verbosity: "high",
      autoCompact: true,
      autoCompactTokenLimit: 90000
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-smart-thread");

  ws.send(
    JSON.stringify({
      id: "mobile-smart-turn",
      type: "turn.start",
      threadId: "thread-1",
      cwd: temp,
      prompt: "권한과 인텔리전스 설정 테스트",
      approvalPolicy: "untrusted",
      sandbox: "workspace-write",
      reasoningEffort: "xhigh",
      reasoningSummary: "concise"
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-smart-turn");

  ws.send(
    JSON.stringify({
      id: "mobile-compact",
      type: "thread.compact",
      threadId: "thread-1"
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-compact" && message.ok === true);
  await waitForMessage(ws, (message) => message.type === "codex.event" && message.method === "thread/compacted");

  const report = await readReport(reportFile);
  expect(report.find((entry) => entry.message.method === "thread/start")?.message).toMatchObject({
    method: "thread/start",
    params: {
      cwd: temp,
      model: "gpt-5.5",
      approvalPolicy: "on-failure",
      approvalsReviewer: "user",
      sandbox: "workspace-write",
      config: {
        model_reasoning_effort: "high",
        model_reasoning_summary: "auto",
        model_verbosity: "high",
        model_auto_compact_token_limit: 90000
      }
    }
  });
  expect(report.find((entry) => entry.message.method === "turn/start")?.message).toMatchObject({
    method: "turn/start",
    params: {
      threadId: "thread-1",
      approvalPolicy: "untrusted",
      approvalsReviewer: "user",
      effort: "xhigh",
      summary: "concise",
      sandboxPolicy: {
        type: "workspaceWrite",
        writableRoots: [temp],
        networkAccess: false
      }
    }
  });
  expect(report.find((entry) => entry.message.method === "thread/compact/start")?.message).toMatchObject({
    method: "thread/compact/start",
    params: { threadId: "thread-1" }
  });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("forks a thread and starts a subagent turn with inherited safe controls", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-subagent",
      type: "subagent.start",
      threadId: "recent-thread-1",
      cwd: temp,
      role: "worker",
      prompt: "테스트 실패 원인을 독립적으로 조사해줘.",
      model: "gpt-5.5",
      reasoningEffort: "high",
      approvalPolicy: "on-request",
      sandbox: "workspace-write"
    })
  );
  const response = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-subagent");
  expect(response).toMatchObject({
    type: "response",
    ok: true,
    result: {
      subagent: {
        parentThreadId: "recent-thread-1",
        threadId: "agent-thread-1",
        role: "worker"
      }
    }
  });

  const report = await readReport(reportFile);
  expect(report.find((entry) => entry.message.method === "thread/fork")?.message).toMatchObject({
    method: "thread/fork",
    params: {
      threadId: "recent-thread-1",
      cwd: temp,
      model: "gpt-5.5",
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandbox: "workspace-write",
      persistExtendedHistory: true
    }
  });
  expect(report.find((entry) => entry.message.method === "turn/start")?.message).toMatchObject({
    method: "turn/start",
    params: {
      threadId: "agent-thread-1",
      model: "gpt-5.5",
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      effort: "high",
      sandboxPolicy: {
        type: "workspaceWrite",
        writableRoots: [temp],
        networkAccess: false
      },
      input: [
        expect.objectContaining({
          type: "text",
          text: expect.stringContaining("테스트 실패 원인을 독립적으로 조사해줘.")
        })
      ]
    }
  });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("saves mobile attachments into the selected workspace and sends codex image/file inputs", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const workspace = path.join(temp, "workspace");
  await mkdir(workspace, { recursive: true });
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: { MOCK_CODEX_REPORT_FILE: reportFile },
    projectRoots: [workspace],
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-thread",
      type: "thread.start",
      cwd: workspace,
      model: "gpt-5.5"
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-thread");

  ws.send(
    JSON.stringify({
      id: "mobile-turn",
      type: "turn.start",
      threadId: "thread-1",
      prompt: "이미지와 파일을 확인해줘.",
      cwd: workspace,
      model: "gpt-5.5",
      attachments: [
        {
          kind: "image",
          filename: "screen.png",
          mimeType: "image/png",
          dataBase64: Buffer.from("fake-image").toString("base64")
        },
        {
          kind: "file",
          filename: "notes.txt",
          mimeType: "text/plain",
          dataBase64: Buffer.from("hello file").toString("base64")
        }
      ]
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-turn");

  const report = await readReport(reportFile);
  const turnStart = report.find((entry) => entry.message.method === "turn/start")?.message;
  expect(turnStart).toMatchObject({
    method: "turn/start",
    params: {
      threadId: "thread-1",
      model: "gpt-5.5",
      input: [
        expect.objectContaining({
          type: "text",
          text: expect.stringContaining("첨부 파일")
        }),
        expect.objectContaining({
          type: "localImage",
          path: expect.stringContaining(".codex-mobile-attachments")
        })
      ]
    }
  });

  const turnParams = turnStart?.params as { input: Array<{ text?: string; path?: string }> };
  const textItem = turnParams.input[0];
  expect(textItem.text).toBeTruthy();
  const text = textItem.text!;
  expect(text).toContain("notes.txt");
  expect(text).toContain(".codex-mobile-attachments");
  const imagePath = turnParams.input[1].path;
  expect(imagePath).toBeTruthy();
  expect(await readFile(imagePath!, "utf8")).toBe("fake-image");
  const filePath = text.match(/notes.txt: (.*notes\.txt)/)?.[1];
  expect(filePath).toBeTruthy();
  expect(await readFile(filePath!, "utf8")).toBe("hello file");

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("lists desktop chat threads and opens one with historical transcript", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "mobile-chat-list", type: "chat.list" }));
  const chatList = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-chat-list");
  expect(chatList).toMatchObject({
    type: "response",
    ok: true,
    result: {
      chats: [
        expect.objectContaining({
          id: "recent-thread-1",
          title: "Desktop chat",
          preview: "이전에 내가 한 질문",
          cwd: temp
        })
      ]
    }
  });

  ws.send(
    JSON.stringify({
      id: "mobile-chat-open",
      type: "chat.open",
      threadId: "recent-thread-1",
      model: "gpt-5.5"
    })
  );
  const opened = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-chat-open");
  expect(opened).toMatchObject({
    type: "response",
    ok: true,
    result: {
      thread: expect.objectContaining({ id: "recent-thread-1" }),
      transcript: [
        expect.objectContaining({ role: "user", text: "이전에 내가 한 질문" }),
        expect.objectContaining({ role: "assistant", text: "이전에 Codex가 한 답변" }),
        expect.objectContaining({ role: "system", text: expect.stringContaining("ls") })
      ]
    }
  });

  const report = await readReport(reportFile);
  expect(report.find((entry) => entry.message.method === "thread/list")?.message).toMatchObject({
    method: "thread/list",
    params: { limit: 50, archived: false }
  });
  expect(report.find((entry) => entry.message.method === "thread/read")?.message).toMatchObject({
    method: "thread/read",
    params: {
      threadId: "recent-thread-1",
      includeTurns: false
    }
  });
  expect(report.find((entry) => entry.message.method === "thread/turns/list")?.message).toMatchObject({
    method: "thread/turns/list",
    params: {
      threadId: "recent-thread-1",
      limit: 30,
      sortDirection: "desc"
    }
  });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("loads older chat transcript pages using cursors", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp,
      MOCK_CODEX_PAGED_THREAD: "1"
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-chat-open-page",
      type: "chat.open",
      threadId: "recent-thread-1",
      turnLimit: 2
    })
  );
  const opened = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-chat-open-page");
  const openedResult = opened.result as Record<string, unknown>;
  expect(openedResult.hasOlderTranscript).toBe(true);
  expect(openedResult.transcriptCursor).toBe("offset:2");
  expect(openedResult.transcript).toEqual([
    expect.objectContaining({ role: "user", text: "paged user 6" }),
    expect.objectContaining({ role: "assistant", text: "paged assistant 6" }),
    expect.objectContaining({ role: "user", text: "paged user 7" }),
    expect.objectContaining({ role: "assistant", text: "paged assistant 7" })
  ]);

  ws.send(
    JSON.stringify({
      id: "mobile-chat-history-page",
      type: "chat.history",
      threadId: "recent-thread-1",
      cursor: openedResult.transcriptCursor,
      limit: 2
    })
  );
  const history = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-chat-history-page");
  const historyResult = history.result as Record<string, unknown>;
  expect(historyResult.hasOlderTranscript).toBe(true);
  expect(historyResult.transcriptCursor).toBe("offset:4");
  expect(historyResult.transcript).toEqual([
    expect.objectContaining({ role: "user", text: "paged user 4" }),
    expect.objectContaining({ role: "assistant", text: "paged assistant 4" }),
    expect.objectContaining({ role: "user", text: "paged user 5" }),
    expect.objectContaining({ role: "assistant", text: "paged assistant 5" })
  ]);

  const report = await readReport(reportFile);
  const turnListRequests = report.filter((entry) => entry.message.method === "thread/turns/list").map((entry) => entry.message);
  expect(turnListRequests).toEqual([
    expect.objectContaining({ params: expect.objectContaining({ limit: 2, sortDirection: "desc" }) }),
    expect.objectContaining({ params: expect.objectContaining({ cursor: "offset:2", limit: 2, sortDirection: "desc" }) })
  ]);

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("opens long desktop chat history without sending oversized thread payloads", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_RECENT_CWD: temp,
      MOCK_CODEX_HUGE_THREAD: "1"
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "mobile-chat-open-huge", type: "chat.open", threadId: "recent-thread-1" }));
  const opened = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-chat-open-huge");
  const payloadBytes = Buffer.byteLength(JSON.stringify(opened), "utf8");
  const result = opened.result as Record<string, unknown>;
  const thread = result.thread as Record<string, unknown>;
  const transcript = result.transcript as Array<Record<string, unknown>>;
  const truncation = result.transcriptTruncation as Record<string, unknown>;

  expect(opened).toMatchObject({ type: "response", ok: true });
  expect(thread.turns).toBeUndefined();
  expect(transcript.length).toBeGreaterThan(0);
  expect(truncation.truncated).toBe(true);
  expect(payloadBytes).toBeLessThan(900_000);

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("persists iPhone-authored prompts into reopened desktop chat history", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);
  const prompt = "아이폰에서 보낸 기록 유지 테스트";

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp,
      MOCK_CODEX_DROP_MOBILE_USER: "1",
      MOCK_CODEX_AUTO_COMPLETE_TURN: "1"
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-persist-turn",
      type: "turn.start",
      threadId: "recent-thread-1",
      prompt
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-persist-turn");
  await waitForMessage(ws, (message) => message.type === "codex.event" && message.method === "turn/completed");

  const inject = await waitForReport(reportFile, (entry) => entry.message.method === "thread/inject_items");
  expect(inject.message).toMatchObject({
    method: "thread/inject_items",
    params: {
      threadId: "recent-thread-1",
      items: [
        {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: prompt }]
        }
      ]
    }
  });

  ws.send(JSON.stringify({ id: "mobile-reopen-after-persist", type: "chat.open", threadId: "recent-thread-1" }));
  const reopened = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-reopen-after-persist");
  const result = reopened.result as Record<string, unknown>;
  const transcript = result.transcript as Array<Record<string, unknown>>;
  expect(transcript).toContainEqual(expect.objectContaining({ role: "user", text: prompt }));

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("persists iPhone-authored prompts after turn start even before completion", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);
  const prompt = "완료 전에 데스크톱 히스토리에 남아야 하는 아이폰 지시";

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp,
      MOCK_CODEX_DROP_MOBILE_USER: "1"
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-persist-before-complete",
      type: "turn.start",
      threadId: "recent-thread-1",
      prompt
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-persist-before-complete");

  const inject = await waitForReport(reportFile, (entry) => entry.message.method === "thread/inject_items");
  expect(inject.message).toMatchObject({
    method: "thread/inject_items",
    params: {
      threadId: "recent-thread-1",
      items: [
        {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: prompt }]
        }
      ]
    }
  });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("queues prompts while a turn is active and starts them in reordered order", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "turn-active", type: "turn.start", threadId: "thread-1", prompt: "first running prompt" }));
  await waitForMessage(ws, (message) => message.id === "turn-active");

  ws.send(JSON.stringify({ id: "turn-queued-1", type: "turn.start", threadId: "thread-1", prompt: "second queued prompt" }));
  const queuedOne = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "turn-queued-1");
  expect(queuedOne).toMatchObject({ type: "response", ok: true, result: { queued: true } });

  ws.send(JSON.stringify({ id: "turn-queued-2", type: "turn.start", threadId: "thread-1", prompt: "third queued prompt" }));
  const queuedTwo = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "turn-queued-2");
  const queuedTwoResult = queuedTwo.result as Record<string, unknown>;
  const queuedTwoItem = queuedTwoResult.queueItem as Record<string, unknown>;

  ws.send(JSON.stringify({ id: "queue-move", type: "queue.move", itemId: queuedTwoItem.id, toIndex: 0 }));
  const moved = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "queue-move");
  const movedResult = moved.result as Record<string, unknown>;
  const movedQueue = movedResult.queue as Array<Record<string, unknown>>;
  expect(movedQueue[0]?.id).toBe(queuedTwoItem.id);

  ws.send(JSON.stringify({ id: "stop-active", type: "turn.stop", threadId: "thread-1" }));
  await waitForMessage(ws, (message) => message.id === "stop-active");

  const startedQueued = await waitForReport(
    reportFile,
    (entry) => entry.message.method === "turn/start" && JSON.stringify(entry.message).includes("third queued prompt")
  );
  expect(startedQueued.message).toMatchObject({ method: "turn/start", params: { threadId: "thread-1" } });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("persists queued prompts across bridge restart and resumes them after mobile reconnect", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const promptQueueFile = path.join(temp, "prompt-queue.json");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    promptQueueFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "turn-active-persist", type: "turn.start", threadId: "thread-1", prompt: "running before restart" }));
  await waitForMessage(ws, (message) => message.id === "turn-active-persist");

  ws.send(JSON.stringify({ id: "turn-queued-persist", type: "turn.start", threadId: "thread-1", prompt: "queued survives restart" }));
  const queued = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "turn-queued-persist");
  const queueItem = (queued.result as Record<string, unknown>).queueItem as Record<string, unknown>;
  expect(queueItem.promptPreview).toBe("queued survives restart");

  await server.stop();
  ws.close();
  const mode = (await stat(promptQueueFile)).mode & 0o777;
  expect(mode).toBe(0o600);

  const restarted = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    promptQueueFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(restarted);

  await restarted.start();
  const restartedAddress = restarted.address();
  const replayWs = await connect(`ws://${restartedAddress.host}:${restartedAddress.port}`, token);
  await waitForMessage(replayWs, (message) => message.type === "bridge.ready");
  const restored = await waitForMessage<Record<string, unknown>>(
    replayWs,
    (message) => message.type === "prompt.queue.updated" && message.count === 1
  );
  const restoredQueue = restored.queue as Array<Record<string, unknown>>;
  expect(restoredQueue[0]?.id).toBe(queueItem.id);

  const started = await waitForMessage<Record<string, unknown>>(
    replayWs,
    (message) => message.type === "prompt.queue.started"
  );
  expect(started.queueItem).toMatchObject({ id: queueItem.id, promptPreview: "queued survives restart" });

  const queuedStart = await waitForReport(
    reportFile,
    (entry) => entry.message.method === "turn/start" && JSON.stringify(entry.message).includes("queued survives restart")
  );
  expect(queuedStart.message).toMatchObject({ method: "turn/start", params: { threadId: "thread-1" } });

  replayWs.close();
  await rm(temp, { recursive: true, force: true });
});

test("steers the active Codex turn with additional mobile input", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const reportFile = path.join(temp, "mock-report.jsonl");
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_REPORT_FILE: reportFile,
      MOCK_CODEX_RECENT_CWD: temp
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "turn-active-steer", type: "turn.start", threadId: "thread-1", prompt: "long running prompt" }));
  await waitForMessage(ws, (message) => message.id === "turn-active-steer");

  ws.send(JSON.stringify({ id: "turn-steer", type: "turn.steer", threadId: "thread-1", prompt: "prioritize the failing test first" }));
  const steered = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "turn-steer");
  expect(steered).toMatchObject({ type: "response", ok: true });

  const report = await waitForReport(reportFile, (entry) => entry.message.method === "turn/steer");
  expect(report.message).toMatchObject({
    method: "turn/steer",
    params: {
      threadId: "thread-1",
      expectedTurnId: "turn-1",
      input: [{ type: "text", text: "prioritize the failing test first", text_elements: [] }]
    }
  });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("writes iPhone-authored prompts to a private desktop handoff inbox", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);
  const mobileHandoffFile = path.join(temp, "mobile-handoff.jsonl");
  const prompt = "데스크톱 Codex가 이어받아야 하는 아이폰 지시";

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    mobileHandoffFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_RECENT_CWD: temp
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(
    JSON.stringify({
      id: "mobile-handoff-turn",
      type: "turn.start",
      threadId: "recent-thread-1",
      prompt,
      cwd: temp,
      model: "gpt-5"
    })
  );
  await waitForMessage(ws, (message) => message.id === "mobile-handoff-turn");

  const handoffStat = await stat(mobileHandoffFile);
  const handoffLines = (await readFile(mobileHandoffFile, "utf8")).trim().split("\n");
  const entry = JSON.parse(handoffLines[0]) as Record<string, unknown>;

  expect((handoffStat.mode & 0o777).toString(8)).toBe("600");
  expect(entry).toMatchObject({
    source: "iphone",
    kind: "turn.start",
    threadId: "recent-thread-1",
    cwd: temp,
    model: "gpt-5",
    prompt
  });
  expect(JSON.stringify(entry)).not.toContain("dataBase64");

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("acknowledges turn.stop as a no-op when no active turn is tracked", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: { MOCK_CODEX_RECENT_CWD: temp },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "mobile-open-idle", type: "chat.open", threadId: "recent-thread-1" }));
  await waitForMessage(ws, (message) => message.id === "mobile-open-idle" && message.ok === true);

  ws.send(JSON.stringify({ id: "mobile-stop-idle", type: "turn.stop", threadId: "recent-thread-1" }));
  const stopped = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-stop-idle");
  expect(stopped).toMatchObject({
    type: "response",
    ok: true,
    result: {
      stopped: false,
      reason: "no_active_turn"
    }
  });

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("returns image and file attachments in reopened chat transcript", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "codex-remote-bridge-"));
  const imagePath = path.join(temp, "photo.png");
  const filePath = path.join(temp, "notes.pdf");
  await writeFile(imagePath, Buffer.from("89504e470d0a1a0a", "hex"), { mode: 0o600 });
  await writeFile(filePath, "hello", { mode: 0o600 });
  const token = randomBytes(32).toString("base64url");
  const tokenFile = await writeTokenFile(temp, token, 0o600);

  const server = new BridgeServer({
    host: "127.0.0.1",
    port: 0,
    tokenFile,
    codexCommand: process.execPath,
    codexArgs: [fixturePath],
    codexEnv: {
      MOCK_CODEX_RECENT_CWD: temp,
      MOCK_CODEX_ATTACHMENT_HISTORY: "1",
      MOCK_CODEX_ATTACHMENT_IMAGE_PATH: imagePath,
      MOCK_CODEX_ATTACHMENT_FILE_PATH: filePath
    },
    logger: createLogger({ sink: () => undefined })
  });
  servers.push(server);

  await server.start();
  const address = server.address();
  const ws = await connect(`ws://${address.host}:${address.port}`, token);
  await waitForMessage(ws, (message) => message.type === "bridge.ready");

  ws.send(JSON.stringify({ id: "mobile-open-attachments", type: "chat.open", threadId: "recent-thread-1" }));
  const opened = await waitForMessage<Record<string, unknown>>(ws, (message) => message.id === "mobile-open-attachments");
  const result = opened.result as Record<string, unknown>;
  const transcript = result.transcript as Array<Record<string, unknown>>;
  const userEntry = transcript.find((entry) => entry.role === "user") as Record<string, unknown>;
  const attachments = userEntry.attachments as Array<Record<string, unknown>>;

  expect(attachments).toEqual([
    expect.objectContaining({
      kind: "file",
      filename: "notes.pdf",
      path: filePath,
      mimeType: "application/pdf",
      byteCount: 5
    }),
    expect.objectContaining({
      kind: "image",
      filename: "photo.png",
      path: imagePath,
      previewDataBase64: Buffer.from("89504e470d0a1a0a", "hex").toString("base64")
    })
  ]);

  ws.close();
  await rm(temp, { recursive: true, force: true });
});

test("closes clients that exceed the outbound backpressure queue", () => {
  const sent: string[] = [];
  const socket = {
    readyState: WebSocket.OPEN,
    bufferedAmount: 1024,
    send: (payload: string, callback?: (error?: Error) => void) => {
      sent.push(payload);
      callback?.();
    },
    close: () => {
      socket.closed = true;
    },
    closed: false
  };
  const sender = new QueuedWebSocketSender(socket, {
    highWatermarkBytes: 1,
    maxQueuedMessages: 1
  });

  sender.send({ type: "codex.event", eventId: 1, method: "first" });
  sender.send({ type: "codex.event", eventId: 2, method: "second" });

  expect(sent).toEqual([]);
  expect(socket.closed).toBe(true);
});
