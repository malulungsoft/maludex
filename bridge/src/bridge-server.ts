import { createServer, type Server as HttpServer } from "node:http";
import { randomBytes } from "node:crypto";
import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import WebSocket, { WebSocketServer } from "ws";
import { CapabilityAuthenticator, loadCapabilityTokenFromFile } from "./auth.js";
import { CodexRpcClient } from "./codex-rpc.js";
import { createLogger, type Logger } from "./logger.js";
import { MobileHandoffStore, handoffAttachments, type NewMobileHandoffEntry } from "./mobile-handoff-store.js";
import { QueuedWebSocketSender } from "./queued-websocket-sender.js";
import {
  asJsonValue,
  isRecord,
  type ApprovalDecision,
  type JsonObject,
  type JsonRpcId,
  type JsonValue,
  type MobileAttachment,
  type MobileMessage,
  type ReasoningEffort,
  type ReasoningSummary,
  type SafeApprovalPolicy,
  type SafeSandbox,
  type SubagentRole,
  type Verbosity
} from "./types.js";

type PendingApproval = {
  codexRequestId: JsonRpcId;
  method: string;
  timer: NodeJS.Timeout;
};

type BufferedEvent = JsonObject & {
  eventId: number;
};

type ProjectSource = "root" | "scan" | "recent" | "created";

type ProjectSummary = {
  path: string;
  name: string;
  source: ProjectSource;
  updatedAt?: number;
};

type MobileAuthoredTurn = {
  threadId: string;
  turnId?: string;
  input: JsonValue[];
};

type QueuedPromptTurn = {
  id: string;
  threadId: string;
  input: JsonValue[];
  params: JsonObject;
  authoredTurn: MobileAuthoredTurn;
  sandbox: SafeSandbox;
  promptPreview: string;
  promptBytes: number;
  attachmentCount: number;
  createdAt: string;
};

const DEFAULT_CHAT_TRANSCRIPT_ENTRY_LIMIT = 120;
const DEFAULT_CHAT_TRANSCRIPT_BYTE_LIMIT = 768 * 1024;
const DEFAULT_CHAT_TRANSCRIPT_ENTRY_TEXT_BYTE_LIMIT = 12 * 1024;
const DEFAULT_CHAT_ATTACHMENT_PREVIEW_BYTE_LIMIT = 512 * 1024;
const DEFAULT_CHAT_HISTORY_TURN_LIMIT = 30;
const MAX_PROMPT_QUEUE_ITEMS = 50;
const BRIDGE_VERSION = "0.6.7";
const MOBILE_PROTOCOL_VERSION = 1;
const MIN_CLIENT_PROTOCOL_VERSION = 1;
const DEFAULT_APPROVAL_REQUEST_TIMEOUT_MS = 10 * 60 * 1000;

export type BridgeServerOptions = {
  host?: string;
  port?: number;
  tokenFile: string;
  codexCommand?: string;
  codexArgs?: string[];
  codexEnv?: NodeJS.ProcessEnv;
  logger?: Logger;
  requestTimeoutMs?: number;
  approvalRequestTimeoutMs?: number;
  eventReplayLimit?: number;
  highWatermarkBytes?: number;
  maxQueuedMessages?: number;
  projectRoots?: string[];
  maxAttachmentBytes?: number;
  maxAttachmentsPerTurn?: number;
  promptQueueFile?: string;
  mobileHandoffFile?: string;
};

export class BridgeServer {
  private readonly host: string;
  private readonly port: number;
  private readonly logger: Logger;
  private readonly tokenFile: string;
  private authenticator: CapabilityAuthenticator;
  private tokenPollTimer: NodeJS.Timeout | null = null;
  private readonly codex: CodexRpcClient;
  private httpServer: HttpServer | null = null;
  private wss: WebSocketServer | null = null;
  private mobile: WebSocket | null = null;
  private mobileSender: QueuedWebSocketSender | null = null;
  private readonly activeTurns = new Map<string, string>();
  private readonly startingThreads = new Set<string>();
  private readonly promptQueues = new Map<string, QueuedPromptTurn[]>();
  private readonly mobileAuthoredTurns = new Map<string, MobileAuthoredTurn>();
  private readonly mobileAuthoredTurnsByThread = new Map<string, MobileAuthoredTurn[]>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private readonly eventBuffer: BufferedEvent[] = [];
  private readonly resumedThreads = new Set<string>();
  private readonly eventReplayLimit: number;
  private readonly highWatermarkBytes: number;
  private readonly maxQueuedMessages: number;
  private readonly projectRoots: string[];
  private readonly maxAttachmentBytes: number;
  private readonly maxAttachmentsPerTurn: number;
  private readonly promptQueueFile: string;
  private readonly mobileHandoffStore: MobileHandoffStore;
  private readonly approvalRequestTimeoutMs: number;
  private nextEventId = 1;
  private nextPromptQueueId = 1;
  private readonly threadCwds = new Map<string, string>();
  private readonly startedAt = Date.now();

  constructor(options: BridgeServerOptions) {
    this.host = options.host ?? "127.0.0.1";
    this.port = options.port ?? 8765;
    this.logger = options.logger ?? createLogger();
    this.tokenFile = options.tokenFile;
    this.authenticator = new CapabilityAuthenticator(loadCapabilityTokenFromFile(options.tokenFile));
    this.eventReplayLimit = options.eventReplayLimit ?? 500;
    this.highWatermarkBytes = options.highWatermarkBytes ?? 1024 * 1024;
    this.approvalRequestTimeoutMs = options.approvalRequestTimeoutMs ?? DEFAULT_APPROVAL_REQUEST_TIMEOUT_MS;
    this.maxQueuedMessages = options.maxQueuedMessages ?? 256;
    this.projectRoots = normalizeProjectRoots(options.projectRoots ?? defaultProjectRoots());
    this.maxAttachmentBytes = options.maxAttachmentBytes ?? 15 * 1024 * 1024;
    this.maxAttachmentsPerTurn = options.maxAttachmentsPerTurn ?? 5;
    this.promptQueueFile = options.promptQueueFile ?? path.join(path.dirname(options.tokenFile), "prompt-queue.json");
    this.mobileHandoffStore = new MobileHandoffStore(
      options.mobileHandoffFile ?? path.join(path.dirname(options.tokenFile), "mobile-handoff.jsonl")
    );
    this.codex = new CodexRpcClient({
      command: options.codexCommand,
      args: options.codexArgs,
      env: options.codexEnv,
      logger: this.logger,
      requestTimeoutMs: options.requestTimeoutMs
    });
  }

  async start(): Promise<void> {
    this.validateBindHost();
    this.loadPromptQueues();
    this.codex.on("notification", (message) => this.handleCodexNotification(message));
    this.codex.on("serverRequest", (message) => this.handleCodexServerRequest(message));
    await this.codex.start();
    this.startTokenPolling();

    this.httpServer = createServer();
    this.wss = new WebSocketServer({ noServer: true });
    this.httpServer.on("upgrade", (request, socket, head) => {
      this.reloadTokenIfChanged();
      if (!this.authenticator.isAuthorized(request)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        this.logger.warn("mobile.auth_failed", { remoteAddress: request.socket.remoteAddress });
        return;
      }

      this.wss?.handleUpgrade(request, socket, head, (ws) => {
        this.wss?.emit("connection", ws, request);
      });
    });
    this.wss.on("connection", (ws, request) => this.handleMobileConnection(ws, request));

    await new Promise<void>((resolve) => {
      this.httpServer?.listen(this.port, this.host, () => resolve());
    });
    this.logger.info("bridge.listening", this.address());
  }

  async stop(): Promise<void> {
    this.stopTokenPolling();
    this.declinePendingApprovals();
    if (this.mobile?.readyState === WebSocket.OPEN) {
      this.mobile.close(1001, "bridge stopping");
    }
    this.mobileSender?.stop();
    this.wss?.clients.forEach((client) => client.close(1001, "bridge stopping"));
    await new Promise<void>((resolve) => {
      if (!this.httpServer) {
        resolve();
        return;
      }
      this.httpServer.close(() => resolve());
    });
    this.httpServer = null;
    this.wss = null;
    await this.codex.stop();
  }

  address(): { host: string; port: number } {
    const address = this.httpServer?.address();
    if (isRecord(address) && typeof address.port === "number") {
      return { host: this.host, port: address.port };
    }
    return { host: this.host, port: this.port };
  }

  private validateBindHost(): void {
    if (this.host === "0.0.0.0" || this.host === "::") {
      throw new Error("Wildcard WebSocket binds are disabled. Bind to 127.0.0.1, ::1, or a specific Tailscale IP.");
    }
  }

  private startTokenPolling(): void {
    this.stopTokenPolling();
    this.tokenPollTimer = setInterval(() => {
      this.reloadTokenIfChanged();
    }, 1000);
    this.tokenPollTimer.unref();
  }

  private stopTokenPolling(): void {
    if (this.tokenPollTimer) {
      clearInterval(this.tokenPollTimer);
      this.tokenPollTimer = null;
    }
  }

  private reloadTokenIfChanged(): void {
    let token: string;
    try {
      token = loadCapabilityTokenFromFile(this.tokenFile);
    } catch (error) {
      this.logger.warn("mobile.token_reload_failed", {
        message: error instanceof Error ? error.message : String(error)
      });
      return;
    }
    if (this.authenticator.hasSameToken(token)) {
      return;
    }
    this.authenticator = new CapabilityAuthenticator(token);
    this.logger.warn("mobile.token_rotated");
    if (this.mobile?.readyState === WebSocket.OPEN) {
      this.mobile.close(4001, "pairing token rotated");
    }
  }

  private handleMobileConnection(ws: WebSocket, request: import("node:http").IncomingMessage): void {
    if (this.mobile && this.mobile.readyState === WebSocket.OPEN) {
      this.mobile.close(4000, "replaced by a new authenticated client");
    }

    this.mobile = ws;
    this.mobileSender = new QueuedWebSocketSender(ws, {
      highWatermarkBytes: this.highWatermarkBytes,
      maxQueuedMessages: this.maxQueuedMessages
    });
    const afterEventId = afterEventIdFromRequest(request);
    this.logger.info("mobile.connected", { remoteAddress: request.socket.remoteAddress, afterEventId });
    setImmediate(() => {
      this.send(ws, {
        type: "bridge.ready",
        protocolVersion: MOBILE_PROTOCOL_VERSION,
        minClientProtocolVersion: MIN_CLIENT_PROTOCOL_VERSION,
        bridgeVersion: BRIDGE_VERSION,
        serverTime: new Date().toISOString(),
        lastEventId: this.lastEventId()
      });
      this.replayEvents(afterEventId);
      this.emitRestoredPromptQueues();
      void this.resumeIdlePromptQueues();
    });

    ws.on("message", (data) => {
      void this.handleMobileMessage(ws, data.toString());
    });
    ws.on("close", () => {
      if (this.mobile === ws) {
        this.mobile = null;
        this.mobileSender?.stop();
        this.mobileSender = null;
      }
      this.logger.info("mobile.disconnected");
    });
  }

  private async handleMobileMessage(ws: WebSocket, raw: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      this.sendError(ws, undefined, "bad_json", "Message must be valid JSON.");
      return;
    }

    if (!isRecord(parsed) || typeof parsed.type !== "string") {
      this.sendError(ws, messageId(parsed), "bad_message", "Message must contain a string type.");
      return;
    }

    const message = parsed as MobileMessage;
    try {
      if (message.type === "thread.start") {
        await this.startThread(ws, message);
      } else if (message.type === "turn.start" || message.type === "turn.send") {
        await this.startTurn(ws, message);
      } else if (message.type === "turn.steer") {
        await this.steerTurn(ws, message);
      } else if (message.type === "turn.stop") {
        await this.stopTurn(ws, message);
      } else if (message.type === "queue.list") {
        this.listPromptQueue(ws, message);
      } else if (message.type === "queue.move") {
        this.movePromptQueueItem(ws, message);
      } else if (message.type === "queue.cancel") {
        this.cancelPromptQueueItem(ws, message);
      } else if (message.type === "approval.respond") {
        await this.respondToApproval(ws, message);
      } else if (message.type === "thread.compact") {
        await this.compactThread(ws, message);
      } else if (message.type === "subagent.start") {
        await this.startSubagent(ws, message);
      } else if (message.type === "project.list") {
        await this.listProjects(ws, message);
      } else if (message.type === "project.create") {
        await this.createProject(ws, message);
      } else if (message.type === "model.list") {
        await this.listModels(ws, message);
      } else if (message.type === "chat.list") {
        await this.listChats(ws, message);
      } else if (message.type === "chat.open") {
        await this.openChat(ws, message);
      } else if (message.type === "chat.history") {
        await this.loadChatHistory(ws, message);
      } else if (message.type === "ping") {
        this.sendOk(ws, message.id, { pong: true });
      } else if (message.type === "bridge.status") {
        this.sendBridgeStatus(ws, message);
      } else {
        this.sendError(ws, messageId(parsed), "unknown_type", `Unsupported message type: ${parsed.type}`);
      }
    } catch (error) {
      const text = error instanceof Error ? error.message : "Unknown bridge error.";
      this.sendError(ws, message.id, "bridge_error", text);
    }
  }

  private async startThread(ws: WebSocket, message: Extract<MobileMessage, { type: "thread.start" }>): Promise<void> {
    const sandbox = safeSandbox(message.sandbox);
    const approvalPolicy = safeApprovalPolicy(message.approvalPolicy);
    const config = configFromMobileSettings(message);
    const params: JsonObject = {
      cwd: typeof message.cwd === "string" ? message.cwd : undefined,
      model: typeof message.model === "string" ? message.model : undefined,
      approvalPolicy,
      approvalsReviewer: "user",
      sandbox,
      config: config ? asJsonValue(config) : undefined,
      ephemeral: typeof message.ephemeral === "boolean" ? message.ephemeral : undefined,
      experimentalRawEvents: false,
      persistExtendedHistory: true
    };

    this.logger.info("mobile.thread_start", {
      id: message.id,
      hasCwd: typeof message.cwd === "string",
      hasModel: typeof message.model === "string",
      sandbox,
      approvalPolicy,
      reasoningEffort: safeReasoningEffort(message.reasoningEffort) ?? null,
      autoCompact: message.autoCompact === true
    });
    const result = await this.codex.request("thread/start", asJsonValue(params));
    this.rememberThreadCwd(result, typeof params.cwd === "string" ? params.cwd : undefined);
    const threadId = threadIdFromThreadResult(result);
    if (threadId) {
      this.resumedThreads.add(threadId);
    }
    this.sendOk(ws, message.id, result);
  }

  private async startTurn(
    ws: WebSocket,
    message: Extract<MobileMessage, { type: "turn.start" | "turn.send" }>
  ): Promise<void> {
    if (typeof message.threadId !== "string" || !message.threadId) {
      throw new Error(`${message.type} requires threadId.`);
    }
    if (typeof message.prompt !== "string" || !message.prompt) {
      throw new Error(`${message.type} requires a non-empty prompt.`);
    }

    const shouldQueue = this.isThreadBusy(message.threadId);
    if (!shouldQueue) {
      this.startingThreads.add(message.threadId);
    }

    const cwd = typeof message.cwd === "string" ? message.cwd : this.threadCwds.get(message.threadId);
    try {
      await this.ensureThreadResumed(message.threadId, message, cwd);
      const input = await this.buildTurnInput(message.prompt, message.attachments, cwd);
      const sandbox = safeSandbox(message.sandbox);
      const params: JsonObject = {
        threadId: message.threadId,
        input,
        cwd: typeof message.cwd === "string" ? message.cwd : undefined,
        model: typeof message.model === "string" ? message.model : undefined,
        approvalPolicy: safeApprovalPolicy(message.approvalPolicy),
        approvalsReviewer: "user",
        sandboxPolicy: asJsonValue(sandboxPolicyFromMode(sandbox, cwd)),
        effort: safeReasoningEffort(message.reasoningEffort),
        summary: safeReasoningSummary(message.reasoningSummary)
      };
      const promptBytes = Buffer.byteLength(message.prompt, "utf8");
      const attachmentCount = Array.isArray(message.attachments) ? message.attachments.length : 0;
      await this.recordMobileHandoff({
        kind: "turn.start",
        threadId: message.threadId,
        cwd,
        model: typeof message.model === "string" ? message.model : undefined,
        prompt: message.prompt,
        promptBytes,
        attachments: handoffAttachments(message.attachments)
      });

      this.logger.info(shouldQueue ? "mobile.turn_queued" : "mobile.turn_start", {
        id: message.id,
        threadId: message.threadId,
        promptBytes,
        attachmentCount,
        hasCwd: typeof message.cwd === "string",
        hasModel: typeof message.model === "string",
        sandbox,
        reasoningEffort: safeReasoningEffort(message.reasoningEffort) ?? null
      });
      const authoredTurn: MobileAuthoredTurn = { threadId: message.threadId, input };
      if (shouldQueue) {
        const queueItem = this.enqueuePromptTurn({
          threadId: message.threadId,
          input,
          params,
          authoredTurn,
          sandbox,
          promptPreview: promptPreview(message.prompt),
          promptBytes,
          attachmentCount
        });
        this.emitPromptQueueUpdated(message.threadId);
        this.sendOk(ws, message.id, asJsonValue({
          queued: true,
          queueItem: publicQueueItem(queueItem),
          queue: this.publicPromptQueue(message.threadId)
        }));
        return;
      }

      const result = await this.dispatchTurnStart(message.threadId, params, authoredTurn);
      this.sendOk(ws, message.id, result);
    } finally {
      if (!shouldQueue) {
        this.startingThreads.delete(message.threadId);
      }
    }
  }

  private async dispatchTurnStart(threadId: string, params: JsonObject, authoredTurn: MobileAuthoredTurn): Promise<JsonValue> {
    this.rememberMobileAuthoredTurn(authoredTurn);
    let result: JsonValue;
    try {
      result = await this.codex.request("turn/start", asJsonValue(params));
    } catch (error) {
      const recoverableTurn = this.takeMobileAuthoredTurn(threadId) ?? authoredTurn;
      void this.persistMobileAuthoredTurn(recoverableTurn);
      throw error;
    }
    const turnId = turnIdFromStartResult(result);
    if (turnId) {
      this.activeTurns.set(threadId, turnId);
      authoredTurn.turnId = turnId;
      if (this.isMobileAuthoredTurnTracked(authoredTurn)) {
        this.mobileAuthoredTurns.set(mobileTurnKey(threadId, turnId), authoredTurn);
      }
    }
    const recoverableTurn = this.takeMobileAuthoredTurn(threadId, turnId ?? undefined) ?? authoredTurn;
    void this.persistMobileAuthoredTurn(recoverableTurn);
    return result;
  }

  private async steerTurn(ws: WebSocket, message: Extract<MobileMessage, { type: "turn.steer" }>): Promise<void> {
    if (typeof message.threadId !== "string" || !message.threadId) {
      throw new Error("turn.steer requires threadId.");
    }
    if (typeof message.prompt !== "string" || !message.prompt.trim()) {
      throw new Error("turn.steer requires a non-empty prompt.");
    }

    const turnId = typeof message.turnId === "string" && message.turnId ? message.turnId : this.activeTurns.get(message.threadId);
    if (!turnId) {
      throw new Error("No active turn is tracked for this thread. Start a turn before steering.");
    }

    const cwd = typeof message.cwd === "string" ? message.cwd : this.threadCwds.get(message.threadId);
    const input = await this.buildTurnInput(message.prompt, message.attachments, cwd);
    const promptBytes = Buffer.byteLength(message.prompt, "utf8");
    await this.recordMobileHandoff({
      kind: "turn.steer",
      threadId: message.threadId,
      turnId,
      cwd,
      prompt: message.prompt,
      promptBytes,
      attachments: handoffAttachments(message.attachments)
    });
    this.logger.info("mobile.turn_steer", {
      id: message.id,
      threadId: message.threadId,
      turnId,
      promptBytes,
      attachmentCount: Array.isArray(message.attachments) ? message.attachments.length : 0,
      hasCwd: typeof message.cwd === "string"
    });
    const result = await this.codex.request("turn/steer", {
      threadId: message.threadId,
      input,
      expectedTurnId: turnId
    });
    this.sendOk(ws, message.id, result);
  }

  private listPromptQueue(ws: WebSocket, message: Extract<MobileMessage, { type: "queue.list" }>): void {
    this.sendOk(ws, message.id, asJsonValue({
      queue: this.publicPromptQueue(message.threadId),
      count: this.promptQueueCount(message.threadId)
    }));
  }

  private movePromptQueueItem(ws: WebSocket, message: Extract<MobileMessage, { type: "queue.move" }>): void {
    if (typeof message.itemId !== "string" || !message.itemId) {
      throw new Error("queue.move requires itemId.");
    }
    if (typeof message.toIndex !== "number" || !Number.isFinite(message.toIndex)) {
      throw new Error("queue.move requires toIndex.");
    }

    const located = this.findQueuedPrompt(message.itemId, message.threadId);
    if (!located) {
      throw new Error("Queued prompt was not found.");
    }

    const [item] = located.queue.splice(located.index, 1);
    const toIndex = Math.max(0, Math.min(Math.floor(message.toIndex), located.queue.length));
    located.queue.splice(toIndex, 0, item);
    this.persistPromptQueues();
    this.emitPromptQueueUpdated(located.threadId);
    this.sendOk(ws, message.id, asJsonValue({
      moved: true,
      queue: this.publicPromptQueue(located.threadId)
    }));
  }

  private cancelPromptQueueItem(ws: WebSocket, message: Extract<MobileMessage, { type: "queue.cancel" }>): void {
    if (typeof message.itemId !== "string" || !message.itemId) {
      throw new Error("queue.cancel requires itemId.");
    }

    const located = this.findQueuedPrompt(message.itemId, message.threadId);
    if (!located) {
      throw new Error("Queued prompt was not found.");
    }

    const [item] = located.queue.splice(located.index, 1);
    if (located.queue.length === 0) {
      this.promptQueues.delete(located.threadId);
    }
    this.persistPromptQueues();
    this.emitPromptQueueUpdated(located.threadId);
    this.sendOk(ws, message.id, asJsonValue({
      cancelled: true,
      queueItem: publicQueueItem(item),
      queue: this.publicPromptQueue(located.threadId)
    }));
  }

  private async stopTurn(ws: WebSocket, message: Extract<MobileMessage, { type: "turn.stop" }>): Promise<void> {
    const threadId = message.threadId ?? firstMapKey(this.activeTurns);
    if (!threadId) {
      this.logger.info("mobile.turn_stop_noop", { id: message.id, reason: "missing_thread" });
      this.sendOk(ws, message.id, { stopped: false, reason: "no_active_turn" });
      return;
    }
    const turnId = message.turnId ?? this.activeTurns.get(threadId);
    if (!turnId) {
      this.logger.info("mobile.turn_stop_noop", { id: message.id, threadId, reason: "no_active_turn" });
      this.sendOk(ws, message.id, { stopped: false, reason: "no_active_turn" });
      return;
    }

    this.logger.info("mobile.turn_stop", { id: message.id, threadId, turnId });
    const result = await this.codex.request("turn/interrupt", { threadId, turnId });
    this.sendOk(ws, message.id, { stopped: true, result });
  }

  private async compactThread(ws: WebSocket, message: Extract<MobileMessage, { type: "thread.compact" }>): Promise<void> {
    if (typeof message.threadId !== "string" || !message.threadId) {
      throw new Error("thread.compact requires threadId.");
    }

    this.logger.info("mobile.thread_compact", { id: message.id, threadId: message.threadId });
    const result = await this.codex.request("thread/compact/start", { threadId: message.threadId });
    this.sendOk(ws, message.id, result);
  }

  private async startSubagent(ws: WebSocket, message: Extract<MobileMessage, { type: "subagent.start" }>): Promise<void> {
    if (typeof message.threadId !== "string" || !message.threadId) {
      throw new Error("subagent.start requires threadId.");
    }
    if (typeof message.prompt !== "string" || !message.prompt.trim()) {
      throw new Error("subagent.start requires a non-empty prompt.");
    }

    const cwd = typeof message.cwd === "string" ? message.cwd : this.threadCwds.get(message.threadId);
    await this.ensureThreadResumed(message.threadId, message, cwd);
    const sandbox = safeSandbox(message.sandbox);
    const approvalPolicy = safeApprovalPolicy(message.approvalPolicy);
    const config = configFromMobileSettings(message);
    const role = safeSubagentRole(message.role);
    const promptBytes = Buffer.byteLength(message.prompt, "utf8");
    await this.recordMobileHandoff({
      kind: "subagent.start",
      threadId: message.threadId,
      cwd,
      model: typeof message.model === "string" ? message.model : undefined,
      role,
      prompt: message.prompt,
      promptBytes,
      attachments: []
    });
    const forkParams: JsonObject = {
      threadId: message.threadId,
      cwd: typeof cwd === "string" ? cwd : undefined,
      model: typeof message.model === "string" && message.model ? message.model : undefined,
      approvalPolicy,
      approvalsReviewer: "user",
      sandbox,
      config: config ? asJsonValue(config) : undefined,
      ephemeral: false,
      persistExtendedHistory: true
    };

    this.logger.info("mobile.subagent_start", {
      id: message.id,
      parentThreadId: message.threadId,
      role,
      hasCwd: typeof cwd === "string",
      hasModel: typeof message.model === "string" && message.model.length > 0,
      sandbox,
      approvalPolicy,
      reasoningEffort: safeReasoningEffort(message.reasoningEffort) ?? null
    });
    const forkResult = await this.codex.request("thread/fork", asJsonValue(forkParams));
    const subagentThreadId = threadIdFromThreadResult(forkResult);
    if (!subagentThreadId) {
      throw new Error("Codex did not return a subagent thread id.");
    }
    this.rememberThreadCwd(forkResult, cwd);

    const input = [{ type: "text", text: subagentPrompt(role, message.prompt), text_elements: [] }];
    const turnParams: JsonObject = {
      threadId: subagentThreadId,
      input,
      cwd: typeof cwd === "string" ? cwd : undefined,
      model: typeof message.model === "string" && message.model ? message.model : undefined,
      approvalPolicy,
      approvalsReviewer: "user",
      sandboxPolicy: asJsonValue(sandboxPolicyFromMode(sandbox, cwd)),
      effort: safeReasoningEffort(message.reasoningEffort),
      summary: safeReasoningSummary(message.reasoningSummary)
    };
    const turnResult = await this.codex.request("turn/start", asJsonValue(turnParams));
    const turnId = turnIdFromStartResult(turnResult);
    if (turnId) {
      this.activeTurns.set(subagentThreadId, turnId);
    }

    this.sendOk(
      ws,
      message.id,
      asJsonValue({
        subagent: {
          parentThreadId: message.threadId,
          threadId: subagentThreadId,
          role
        },
        fork: resumeResultForMobile(forkResult, isRecord(forkResult) && isRecord(forkResult.thread) ? forkResult.thread : null),
        turn: turnResult
      })
    );
  }

  private async respondToApproval(
    ws: WebSocket,
    message: Extract<MobileMessage, { type: "approval.respond" }>
  ): Promise<void> {
    const pending = this.pendingApprovals.get(message.approvalId);
    if (!pending) {
      throw new Error(`Unknown approvalId ${message.approvalId}.`);
    }

    const result =
      message.result !== undefined
        ? message.result
        : approvalResult(pending.method, message.decision ?? "decline", message.permissions, message.scope);
    this.codex.respond(pending.codexRequestId, result);
    clearTimeout(pending.timer);
    this.pendingApprovals.delete(message.approvalId);
    this.logger.info("mobile.approval_response", {
      id: message.id,
      approvalId: message.approvalId,
      method: pending.method,
      decision: message.decision ?? "custom"
    });
    this.sendOk(ws, message.id, { accepted: true });
  }

  private async listProjects(ws: WebSocket, message: Extract<MobileMessage, { type: "project.list" }>): Promise<void> {
    const scanned = await this.scanProjectRoots();
    const recent = await this.recentProjects();
    const projects = dedupeProjects([...recent, ...scanned]).slice(0, 200);
    this.sendOk(ws, message.id, {
      roots: this.projectRoots.map((root) => ({ path: root, name: path.basename(root) || root })),
      projects
    });
  }

  private async createProject(
    ws: WebSocket,
    message: Extract<MobileMessage, { type: "project.create" }>
  ): Promise<void> {
    const root = normalizeAbsolutePath(message.root);
    if (!root || !this.projectRoots.includes(root)) {
      throw new Error("project.create root must be one of the configured project roots.");
    }
    const name = safeProjectName(message.name);
    const projectPath = path.join(root, name);
    if (!isPathInside(root, projectPath)) {
      throw new Error("project.create resolved outside the selected root.");
    }

    await mkdir(projectPath, { recursive: false });
    const project: ProjectSummary = { path: projectPath, name, source: "created" };
    this.sendOk(ws, message.id, { project });
  }

  private async listModels(ws: WebSocket, message: Extract<MobileMessage, { type: "model.list" }>): Promise<void> {
    const result = await this.codex.request("model/list", { limit: 100, includeHidden: false });
    this.sendOk(ws, message.id, result);
  }

  private async listChats(ws: WebSocket, message: Extract<MobileMessage, { type: "chat.list" }>): Promise<void> {
    const requestedLimit = message.limit;
    const limit =
      typeof requestedLimit === "number" && Number.isInteger(requestedLimit) && requestedLimit > 0 && requestedLimit <= 100
        ? requestedLimit
        : 50;
    const params: JsonObject = {
      limit,
      cursor: typeof message.cursor === "string" ? message.cursor : undefined,
      sortKey: "updated_at",
      sortDirection: "desc",
      archived: false,
      searchTerm: typeof message.searchTerm === "string" && message.searchTerm.trim() ? message.searchTerm.trim() : undefined
    };
    const result = await this.codex.request("thread/list", asJsonValue(params));
    const rawThreads = isRecord(result) && Array.isArray(result.data) ? (result.data as unknown[]) : [];
    const chats = rawThreads.filter(isRecord).map((thread) => asJsonValue(chatSummaryFromThread(thread)));
    this.logger.info("mobile.chat_list", { id: message.id, count: chats.length });
    this.sendOk(ws, message.id, asJsonValue({
      chats,
      nextCursor: isRecord(result) ? asJsonValue(result.nextCursor) : null,
      backwardsCursor: isRecord(result) ? asJsonValue(result.backwardsCursor) : null
    }));
  }

  private async openChat(ws: WebSocket, message: Extract<MobileMessage, { type: "chat.open" }>): Promise<void> {
    if (typeof message.threadId !== "string" || !message.threadId) {
      throw new Error("chat.open requires threadId.");
    }
    this.logger.info("mobile.chat_open", {
      id: message.id,
      threadId: message.threadId,
      hasModel: typeof message.model === "string" && message.model.length > 0,
      sandbox: safeSandbox(message.sandbox),
      approvalPolicy: safeApprovalPolicy(message.approvalPolicy),
      reasoningEffort: safeReasoningEffort(message.reasoningEffort) ?? null,
      autoCompact: message.autoCompact === true
    });
    const thread = await this.readThreadMetadata(message.threadId);
    if (thread) {
      this.rememberThreadCwd(asJsonValue({ thread }));
    }
    const history = await this.chatHistoryPage(message.threadId, {
      cursor: undefined,
      turnLimit: boundedInteger(message.turnLimit, 1, 100, DEFAULT_CHAT_HISTORY_TURN_LIMIT),
      entryLimit: boundedInteger(message.transcriptLimit, 1, 500, DEFAULT_CHAT_TRANSCRIPT_ENTRY_LIMIT),
      byteLimit: boundedInteger(message.transcriptByteLimit, 64 * 1024, 2 * 1024 * 1024, DEFAULT_CHAT_TRANSCRIPT_BYTE_LIMIT)
    });
    this.sendOk(ws, message.id, asJsonValue({
      thread: thread ? asJsonValue(threadForMobile(thread)) : undefined,
      model: typeof message.model === "string" && message.model ? message.model : undefined,
      cwd: thread && typeof thread.cwd === "string" ? thread.cwd : undefined,
      transcript: history.entries,
      transcriptTruncation: asJsonValue(history.truncation),
      transcriptCursor: history.nextCursor,
      transcriptBackwardsCursor: history.backwardsCursor,
      hasOlderTranscript: history.nextCursor !== null
    }));
  }

  private async loadChatHistory(
    ws: WebSocket,
    message: Extract<MobileMessage, { type: "chat.history" }>
  ): Promise<void> {
    if (typeof message.threadId !== "string" || !message.threadId) {
      throw new Error("chat.history requires threadId.");
    }
    const history = await this.chatHistoryPage(message.threadId, {
      cursor: typeof message.cursor === "string" && message.cursor ? message.cursor : undefined,
      turnLimit: boundedInteger(message.limit, 1, 100, DEFAULT_CHAT_HISTORY_TURN_LIMIT),
      entryLimit: DEFAULT_CHAT_TRANSCRIPT_ENTRY_LIMIT,
      byteLimit: boundedInteger(message.transcriptByteLimit, 64 * 1024, 2 * 1024 * 1024, DEFAULT_CHAT_TRANSCRIPT_BYTE_LIMIT)
    });
    this.logger.info("mobile.chat_history", {
      id: message.id,
      threadId: message.threadId,
      returnedEntryCount: history.entries.length,
      hasOlder: history.nextCursor !== null
    });
    this.sendOk(ws, message.id, asJsonValue({
      transcript: history.entries,
      transcriptTruncation: asJsonValue(history.truncation),
      transcriptCursor: history.nextCursor,
      transcriptBackwardsCursor: history.backwardsCursor,
      hasOlderTranscript: history.nextCursor !== null
    }));
  }

  private sendBridgeStatus(ws: WebSocket, message: Extract<MobileMessage, { type: "bridge.status" }>): void {
    const address = this.address();
    const status = {
      bridgeVersion: BRIDGE_VERSION,
      protocolVersion: MOBILE_PROTOCOL_VERSION,
      minClientProtocolVersion: MIN_CLIENT_PROTOCOL_VERSION,
      host: address.host,
      port: address.port,
      usesTLS: false,
      tokenFileValid: this.isTokenFileValid(),
      codexRunning: this.codex.isRunning(),
      connectedClient: this.mobile?.readyState === WebSocket.OPEN,
      eventBufferSize: this.eventBuffer.length,
      eventReplayLimit: this.eventReplayLimit,
      activeTurnCount: this.activeTurns.size,
      promptQueueCount: this.promptQueueCount(),
      pendingApprovalCount: this.pendingApprovals.size,
      activeTurns: [...this.activeTurns.entries()].map(([threadId, turnId]) => ({ threadId, turnId })),
      promptQueue: this.publicPromptQueue(),
      pendingApprovals: [...this.pendingApprovals.entries()].map(([approvalId, approval]) => ({
        approvalId,
        method: approval.method
      })),
      projectRootCount: this.projectRoots.length,
      resumedThreadCount: this.resumedThreads.size,
      uptimeSeconds: Math.max(0, Math.floor((Date.now() - this.startedAt) / 1000))
    };
    this.logger.info("mobile.bridge_status", {
      id: message.id,
      connectedClient: status.connectedClient,
      codexRunning: status.codexRunning,
      activeTurnCount: status.activeTurnCount,
      promptQueueCount: status.promptQueueCount,
      pendingApprovalCount: status.pendingApprovalCount
    });
    this.sendOk(ws, message.id, asJsonValue(status));
  }

  private isThreadBusy(threadId: string): boolean {
    return this.activeTurns.has(threadId) || this.startingThreads.has(threadId);
  }

  private enqueuePromptTurn(options: Omit<QueuedPromptTurn, "id" | "createdAt">): QueuedPromptTurn {
    const queue = this.promptQueues.get(options.threadId) ?? [];
    if (queue.length >= MAX_PROMPT_QUEUE_ITEMS) {
      throw new Error(`Prompt queue is full. Wait for an active turn or remove queued prompts first.`);
    }

    const item: QueuedPromptTurn = {
      ...options,
      id: `queue-${this.nextPromptQueueId++}`,
      createdAt: new Date().toISOString()
    };
    queue.push(item);
    this.promptQueues.set(options.threadId, queue);
    this.persistPromptQueues();
    return item;
  }

  private publicPromptQueue(threadId?: string): JsonObject[] {
    if (threadId) {
      return (this.promptQueues.get(threadId) ?? []).map(publicQueueItem);
    }

    return [...this.promptQueues.values()].flatMap((queue) => queue.map(publicQueueItem));
  }

  private promptQueueCount(threadId?: string): number {
    if (threadId) {
      return this.promptQueues.get(threadId)?.length ?? 0;
    }
    return [...this.promptQueues.values()].reduce((count, queue) => count + queue.length, 0);
  }

  private findQueuedPrompt(itemId: string, threadId?: string): { threadId: string; queue: QueuedPromptTurn[]; index: number } | null {
    const queues = threadId ? [[threadId, this.promptQueues.get(threadId) ?? []] as const] : [...this.promptQueues.entries()];
    for (const [candidateThreadId, queue] of queues) {
      const index = queue.findIndex((item) => item.id === itemId);
      if (index >= 0) {
        return { threadId: candidateThreadId, queue, index };
      }
    }
    return null;
  }

  private emitPromptQueueUpdated(threadId: string): void {
    this.emitToMobile({
      type: "prompt.queue.updated",
      threadId,
      queue: asJsonValue(this.publicPromptQueue(threadId)),
      count: this.promptQueueCount(threadId)
    });
  }

  private emitRestoredPromptQueues(): void {
    for (const [threadId, queue] of this.promptQueues) {
      if (queue.length > 0) {
        this.emitPromptQueueUpdated(threadId);
      }
    }
  }

  private async resumeIdlePromptQueues(): Promise<void> {
    for (const threadId of [...this.promptQueues.keys()]) {
      if (!this.isThreadBusy(threadId)) {
        await this.startNextQueuedTurn(threadId);
      }
    }
  }

  private async startNextQueuedTurn(threadId: string): Promise<void> {
    if (this.isThreadBusy(threadId)) {
      return;
    }

    const queue = this.promptQueues.get(threadId) ?? [];
    const next = queue.shift();
    if (!next) {
      this.promptQueues.delete(threadId);
      this.emitPromptQueueUpdated(threadId);
      return;
    }
    if (queue.length === 0) {
      this.promptQueues.delete(threadId);
    } else {
      this.promptQueues.set(threadId, queue);
    }
    this.persistPromptQueues();
    this.emitPromptQueueUpdated(threadId);

    this.startingThreads.add(threadId);
    let shouldContinueAfterFailure = false;
    try {
      this.logger.info("mobile.turn_queue_start", {
        queueItemId: next.id,
        threadId,
        promptBytes: next.promptBytes,
        attachmentCount: next.attachmentCount
      });
      await this.ensureThreadResumed(
        threadId,
        {
          model: next.params.model,
          approvalPolicy: next.params.approvalPolicy,
          sandbox: next.sandbox,
          reasoningEffort: next.params.effort,
          reasoningSummary: next.params.summary
        },
        typeof next.params.cwd === "string" ? next.params.cwd : undefined
      );
      await this.dispatchTurnStart(threadId, next.params, next.authoredTurn);
      this.emitToMobile({
        type: "prompt.queue.started",
        threadId,
        queueItem: asJsonValue(publicQueueItem(next))
      });
    } catch (error) {
      shouldContinueAfterFailure = true;
      this.logger.warn("mobile.turn_queue_failed", {
        queueItemId: next.id,
        threadId,
        message: error instanceof Error ? error.message : String(error)
      });
      this.emitToMobile({
        type: "prompt.queue.failed",
        threadId,
        queueItem: asJsonValue(publicQueueItem(next)),
        message: error instanceof Error ? error.message : String(error)
      });
    } finally {
      this.startingThreads.delete(threadId);
    }
    if (shouldContinueAfterFailure) {
      void this.startNextQueuedTurn(threadId);
    }
  }

  private isTokenFileValid(): boolean {
    try {
      loadCapabilityTokenFromFile(this.tokenFile);
      return true;
    } catch {
      return false;
    }
  }

  private loadPromptQueues(): void {
    if (!existsSync(this.promptQueueFile)) {
      return;
    }
    try {
      const parsed = JSON.parse(readFileSync(this.promptQueueFile, "utf8")) as unknown;
      const queues = promptQueueStoreFromJson(parsed);
      this.promptQueues.clear();
      let maxQueueId = 0;
      for (const [threadId, items] of queues) {
        if (items.length === 0) {
          continue;
        }
        this.promptQueues.set(threadId, items);
        for (const item of items) {
          maxQueueId = Math.max(maxQueueId, numericQueueId(item.id));
        }
      }
      this.nextPromptQueueId = Math.max(this.nextPromptQueueId, maxQueueId + 1);
      this.logger.info("mobile.prompt_queue_loaded", { promptQueueCount: this.promptQueueCount() });
    } catch (error) {
      this.logger.warn("mobile.prompt_queue_load_failed", {
        message: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private persistPromptQueues(): void {
    try {
      mkdirSync(path.dirname(this.promptQueueFile), { recursive: true, mode: 0o700 });
      const payload = {
        version: 1,
        updatedAt: new Date().toISOString(),
        queues: [...this.promptQueues.entries()].map(([threadId, items]) => ({ threadId, items }))
      };
      const tempFile = path.join(
        path.dirname(this.promptQueueFile),
        `.${path.basename(this.promptQueueFile)}.${process.pid}.${Date.now()}.tmp`
      );
      writeFileSync(tempFile, `${JSON.stringify(payload)}\n`, { mode: 0o600 });
      chmodSync(tempFile, 0o600);
      renameSync(tempFile, this.promptQueueFile);
      chmodSync(this.promptQueueFile, 0o600);
    } catch (error) {
      this.logger.warn("mobile.prompt_queue_persist_failed", {
        message: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private handleCodexNotification(message: JsonValue): void {
    if (!isRecord(message) || typeof message.method !== "string") {
      return;
    }
    const params = isRecord(message.params) ? message.params : undefined;
    if (message.method === "turn/started" && params) {
      const threadId = typeof params.threadId === "string" ? params.threadId : null;
      const turn = isRecord(params.turn) ? params.turn : null;
      const turnId = turn && typeof turn.id === "string" ? turn.id : null;
      if (threadId && turnId) {
        this.activeTurns.set(threadId, turnId);
      }
    }
    if (message.method === "thread/started" && params) {
      const thread = isRecord(params.thread) ? params.thread : null;
      if (thread && typeof thread.id === "string" && typeof thread.cwd === "string") {
        this.threadCwds.set(thread.id, thread.cwd);
      }
      if (thread && typeof thread.id === "string") {
        this.resumedThreads.add(thread.id);
      }
    }
    if (message.method === "turn/completed" && params) {
      const threadId = typeof params.threadId === "string" ? params.threadId : null;
      const turn = isRecord(params.turn) ? params.turn : null;
      const turnId = turn && typeof turn.id === "string" ? turn.id : null;
      const shouldDrainQueue = threadId !== null && (!turnId || this.activeTurns.get(threadId) === turnId);
      if (threadId && shouldDrainQueue) {
        this.activeTurns.delete(threadId);
      }
      if (threadId) {
        const authoredTurn = this.takeMobileAuthoredTurn(threadId, turnId ?? undefined);
        if (authoredTurn) {
          void this.persistMobileAuthoredTurn(authoredTurn);
        }
      }
      if (threadId && shouldDrainQueue) {
        void this.startNextQueuedTurn(threadId);
      }
    }

    this.emitToMobile({
      type: "codex.event",
      method: message.method,
      params: mobileSafeCodexParams(message.method, message.params)
    });
  }

  private handleCodexServerRequest(message: JsonValue): void {
    if (!isRecord(message) || typeof message.method !== "string" || !("id" in message)) {
      return;
    }
    const approvalId = String(message.id);
    const timer = setTimeout(() => {
      this.timeoutApproval(approvalId);
    }, this.approvalRequestTimeoutMs);
    this.pendingApprovals.set(approvalId, {
      codexRequestId: message.id as JsonRpcId,
      method: message.method,
      timer
    });

    if (!this.mobile || this.mobile.readyState !== WebSocket.OPEN) {
      this.logger.warn("approval.waiting_for_mobile", { approvalId, method: message.method });
    }

    this.emitToMobile({
      type: "approval.requested",
      approvalId,
      method: message.method,
      params: asJsonValue(message.params)
    });
  }

  private declinePendingApprovals(): void {
    for (const approvalId of [...this.pendingApprovals.keys()]) {
      this.declineApproval(approvalId);
    }
  }

  private declineApproval(approvalId: string): void {
    const pending = this.pendingApprovals.get(approvalId);
    if (!pending) {
      return;
    }
    this.codex.respond(pending.codexRequestId, approvalResult(pending.method, "decline"));
    clearTimeout(pending.timer);
    this.pendingApprovals.delete(approvalId);
    this.logger.warn("approval.declined_without_client", { approvalId, method: pending.method });
  }

  private timeoutApproval(approvalId: string): void {
    const pending = this.pendingApprovals.get(approvalId);
    if (!pending) {
      return;
    }
    this.codex.respond(pending.codexRequestId, approvalResult(pending.method, "decline"));
    this.pendingApprovals.delete(approvalId);
    this.logger.warn("approval.timed_out", { approvalId, method: pending.method });
  }

  private sendToMobile(message: JsonValue | JsonObject): void {
    if (!this.mobile || this.mobile.readyState !== WebSocket.OPEN) {
      return;
    }
    this.send(this.mobile, message);
  }

  private rememberThreadCwd(result: JsonValue, fallbackCwd?: string): void {
    if (!isRecord(result) || !isRecord(result.thread) || typeof result.thread.id !== "string") {
      return;
    }
    const cwd = typeof result.cwd === "string" ? result.cwd : typeof result.thread.cwd === "string" ? result.thread.cwd : fallbackCwd;
    if (cwd) {
      this.threadCwds.set(result.thread.id, cwd);
    }
  }

  private async readThreadMetadata(threadId: string): Promise<Record<string, unknown> | null> {
    const result = await this.codex.request("thread/read", { threadId, includeTurns: false });
    return isRecord(result) && isRecord(result.thread) ? result.thread : null;
  }

  private async ensureThreadResumed(
    threadId: string,
    message: {
      model?: unknown;
      approvalPolicy?: unknown;
      sandbox?: unknown;
      reasoningEffort?: unknown;
      reasoningSummary?: unknown;
      verbosity?: unknown;
      autoCompact?: unknown;
      autoCompactTokenLimit?: unknown;
    },
    cwd?: string
  ): Promise<void> {
    if (this.resumedThreads.has(threadId)) {
      return;
    }

    const sandbox = safeSandbox(message.sandbox);
    const approvalPolicy = safeApprovalPolicy(message.approvalPolicy);
    const config = configFromMobileSettings(message);
    const params: JsonObject = {
      threadId,
      cwd: typeof cwd === "string" ? cwd : undefined,
      model: typeof message.model === "string" && message.model ? message.model : undefined,
      approvalPolicy,
      approvalsReviewer: "user",
      sandbox,
      config: config ? asJsonValue(config) : undefined,
      persistExtendedHistory: true
    };
    this.logger.info("mobile.thread_resume_for_turn", {
      threadId,
      hasCwd: typeof cwd === "string",
      hasModel: typeof message.model === "string" && message.model.length > 0,
      sandbox,
      approvalPolicy
    });
    const result = await this.codex.request("thread/resume", asJsonValue(params));
    this.rememberThreadCwd(result, cwd);
    this.resumedThreads.add(threadId);
  }

  private async chatHistoryPage(
    threadId: string,
    options: {
      cursor?: string;
      turnLimit: number;
      entryLimit: number;
      byteLimit: number;
    }
  ): Promise<TranscriptResult & { nextCursor: string | null; backwardsCursor: string | null }> {
    const result = await this.codex.request(
      "thread/turns/list",
      asJsonValue({
        threadId,
        cursor: options.cursor,
        limit: options.turnLimit,
        sortDirection: "desc"
      })
    );
    const turns = isRecord(result) && Array.isArray(result.data) ? (result.data as unknown[]).filter(isRecord) : [];
    const transcript = await transcriptFromTurns(
      turns,
      threadId,
      { entryLimit: options.entryLimit, byteLimit: options.byteLimit },
      true
    );
    return {
      ...transcript,
      nextCursor: isRecord(result) && typeof result.nextCursor === "string" ? result.nextCursor : null,
      backwardsCursor: isRecord(result) && typeof result.backwardsCursor === "string" ? result.backwardsCursor : null
    };
  }

  private rememberMobileAuthoredTurn(record: MobileAuthoredTurn): void {
    if (record.turnId) {
      this.mobileAuthoredTurns.set(mobileTurnKey(record.threadId, record.turnId), record);
    }
    const records = this.mobileAuthoredTurnsByThread.get(record.threadId) ?? [];
    records.push(record);
    this.mobileAuthoredTurnsByThread.set(record.threadId, records.slice(-20));
  }

  private async recordMobileHandoff(entry: NewMobileHandoffEntry): Promise<void> {
    try {
      await this.mobileHandoffStore.record(entry);
      this.logger.info("mobile.handoff_recorded", {
        kind: entry.kind,
        threadId: entry.threadId,
        turnId: entry.turnId ?? null,
        promptBytes: entry.promptBytes,
        attachmentCount: entry.attachments.length
      });
    } catch (error) {
      this.logger.warn("mobile.handoff_record_failed", {
        kind: entry.kind,
        threadId: entry.threadId,
        message: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private takeMobileAuthoredTurn(threadId: string, turnId?: string): MobileAuthoredTurn | null {
    if (turnId) {
      const key = mobileTurnKey(threadId, turnId);
      const record = this.mobileAuthoredTurns.get(key);
      if (record) {
        this.mobileAuthoredTurns.delete(key);
        this.removeMobileAuthoredTurnFromThread(record);
        return record;
      }
    }

    const records = this.mobileAuthoredTurnsByThread.get(threadId) ?? [];
    const record = records.shift();
    if (!record) {
      return null;
    }
    if (records.length === 0) {
      this.mobileAuthoredTurnsByThread.delete(threadId);
    } else {
      this.mobileAuthoredTurnsByThread.set(threadId, records);
    }
    if (record.turnId) {
      this.mobileAuthoredTurns.delete(mobileTurnKey(threadId, record.turnId));
    }
    return record;
  }

  private removeMobileAuthoredTurnFromThread(record: MobileAuthoredTurn): void {
    const records = this.mobileAuthoredTurnsByThread.get(record.threadId) ?? [];
    const next = records.filter((candidate) => candidate !== record);
    if (next.length === 0) {
      this.mobileAuthoredTurnsByThread.delete(record.threadId);
    } else {
      this.mobileAuthoredTurnsByThread.set(record.threadId, next);
    }
  }

  private isMobileAuthoredTurnTracked(record: MobileAuthoredTurn): boolean {
    return (this.mobileAuthoredTurnsByThread.get(record.threadId) ?? []).includes(record);
  }

  private async persistMobileAuthoredTurn(record: MobileAuthoredTurn): Promise<void> {
    try {
      const thread = await this.readRecentTurnsForPersistence(record.threadId);
      if (thread && threadContainsUserInput(thread, record.input)) {
        this.logger.info("mobile.turn_already_persisted", {
          threadId: record.threadId,
          turnId: record.turnId ?? null
        });
        return;
      }

      const items = responseItemsFromUserInput(record.input);
      if (items.length === 0) {
        return;
      }
      await this.codex.request("thread/inject_items", {
        threadId: record.threadId,
        items
      });
      this.logger.info("mobile.turn_injected_into_thread", {
        threadId: record.threadId,
        turnId: record.turnId ?? null,
        itemCount: items.length
      });
    } catch (error) {
      this.logger.warn("mobile.turn_persist_failed", {
        threadId: record.threadId,
        turnId: record.turnId ?? null,
        message: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private async readRecentTurnsForPersistence(threadId: string): Promise<Record<string, unknown> | null> {
    try {
      const recentTurns = await this.codex.request("thread/turns/list", {
        threadId,
        limit: 10,
        sortDirection: "desc"
      });
      if (isRecord(recentTurns) && Array.isArray(recentTurns.data)) {
        return { turns: recentTurns.data };
      }
    } catch (error) {
      this.logger.warn("mobile.turn_recent_read_failed", {
        threadId,
        message: error instanceof Error ? error.message : String(error)
      });
    }

    const read = await this.codex.request("thread/read", { threadId, includeTurns: true });
    return isRecord(read) && isRecord(read.thread) ? read.thread : null;
  }

  private async buildTurnInput(
    prompt: string,
    attachments: MobileAttachment[] | undefined,
    cwd: string | undefined
  ): Promise<JsonValue[]> {
    if (!Array.isArray(attachments) || attachments.length === 0) {
      return [{ type: "text", text: prompt, text_elements: [] }];
    }
    if (attachments.length > this.maxAttachmentsPerTurn) {
      throw new Error(`At most ${this.maxAttachmentsPerTurn} attachments are allowed per turn.`);
    }
    if (!cwd) {
      throw new Error("Attachments require a selected project workspace.");
    }

    const saved = await this.saveAttachments(cwd, attachments);
    const lines = saved.map((attachment) => {
      const mime = attachment.mimeType ? `, ${attachment.mimeType}` : "";
      return `- ${attachment.filename}: ${attachment.path} (${attachment.kind}${mime}, ${attachment.bytes} bytes)`;
    });
    const text = `${prompt}\n\n첨부 파일:\n${lines.join("\n")}`;
    return [
      { type: "text", text, text_elements: [] },
      ...saved
        .filter((attachment) => attachment.kind === "image")
        .map((attachment) => ({ type: "localImage", path: attachment.path }))
    ];
  }

  private async saveAttachments(cwd: string, attachments: MobileAttachment[]): Promise<
    Array<{
      kind: "image" | "file";
      filename: string;
      mimeType?: string;
      bytes: number;
      path: string;
    }>
  > {
    const absoluteCwd = normalizeAbsolutePath(cwd);
    if (!absoluteCwd) {
      throw new Error("Attachment workspace must be an absolute path.");
    }
    const attachmentDirectory = path.join(absoluteCwd, ".codex-mobile-attachments");
    await mkdir(attachmentDirectory, { recursive: true });

    const saved = [];
    for (const attachment of attachments) {
      if (!isMobileAttachment(attachment)) {
        throw new Error("Attachment must include kind, filename, and base64 data.");
      }
      const data = Buffer.from(attachment.dataBase64, "base64");
      if (data.byteLength > this.maxAttachmentBytes) {
        throw new Error(`Attachment ${attachment.filename} exceeds the ${this.maxAttachmentBytes} byte limit.`);
      }
      const filename = safeAttachmentFilename(attachment.filename);
      const savedPath = path.join(attachmentDirectory, `${timestampForFilename()}-${randomBytes(4).toString("hex")}-${filename}`);
      if (!isPathInside(attachmentDirectory, savedPath)) {
        throw new Error("Attachment resolved outside the attachment directory.");
      }
      await writeFile(savedPath, data, { mode: 0o600 });
      saved.push({
        kind: attachment.kind,
        filename,
        mimeType: typeof attachment.mimeType === "string" ? attachment.mimeType : undefined,
        bytes: data.byteLength,
        path: savedPath
      });
    }
    return saved;
  }

  private async scanProjectRoots(): Promise<ProjectSummary[]> {
    const projects: ProjectSummary[] = [];
    for (const root of this.projectRoots) {
      const rootProject = await projectSummary(root, "root");
      if (rootProject) {
        projects.push(rootProject);
      }

      let entries: import("node:fs").Dirent[];
      try {
        entries = await readdir(root, { withFileTypes: true });
      } catch {
        continue;
      }
      for (const entry of entries) {
        if (!entry.isDirectory() || entry.name.startsWith(".")) {
          continue;
        }
        const fullPath = path.join(root, entry.name);
        const project = await projectSummary(fullPath, "scan");
        if (project) {
          projects.push(project);
        }
      }
    }
    return projects;
  }

  private async recentProjects(): Promise<ProjectSummary[]> {
    try {
      const result = await this.codex.request("thread/list", {
        limit: 50,
        sortKey: "updated_at",
        sortDirection: "desc",
        archived: false
      });
      if (!isRecord(result) || !Array.isArray(result.data)) {
        return [];
      }
      const projects: ProjectSummary[] = [];
      for (const thread of result.data as unknown[]) {
        if (!isRecord(thread) || typeof thread.cwd !== "string") {
          continue;
        }
        const cwd = thread.cwd;
        projects.push({
            path: cwd,
            name: path.basename(cwd) || cwd,
            source: "recent",
            updatedAt: typeof thread.updatedAt === "number" ? thread.updatedAt : undefined
        });
      }
      return projects;
    } catch (error) {
      this.logger.warn("project.recent_failed", { message: error instanceof Error ? error.message : String(error) });
      return [];
    }
  }

  private emitToMobile(message: JsonObject): void {
    const event: BufferedEvent = {
      ...message,
      eventId: this.nextEventId++
    };
    this.eventBuffer.push(event);
    if (this.eventBuffer.length > this.eventReplayLimit) {
      this.eventBuffer.splice(0, this.eventBuffer.length - this.eventReplayLimit);
    }
    this.sendToMobile(event);
  }

  private replayEvents(afterEventId: number): void {
    if (!this.mobile || this.mobile.readyState !== WebSocket.OPEN) {
      return;
    }
    for (const event of this.eventBuffer) {
      if (event.eventId > afterEventId) {
        this.send(this.mobile, { ...event, replayed: true });
      }
    }
  }

  private lastEventId(): number {
    return this.nextEventId - 1;
  }

  private sendOk(ws: WebSocket, id: string | undefined, result: JsonValue): void {
    const response: JsonObject = { type: "response", ok: true, result };
    if (id) {
      response.id = id;
    }
    this.send(ws, response);
  }

  private sendError(ws: WebSocket, id: string | undefined, code: string, message: string): void {
    const response: JsonObject = { type: "response", ok: false, error: { code, message } };
    if (id) {
      response.id = id;
    }
    this.send(ws, response);
  }

  private send(ws: WebSocket, message: JsonValue | JsonObject): void {
    if (ws.readyState !== WebSocket.OPEN) {
      return;
    }
    if (this.mobile === ws && this.mobileSender) {
      this.mobileSender.send(message);
      return;
    }
    ws.send(JSON.stringify(message));
  }
}

function afterEventIdFromRequest(request: import("node:http").IncomingMessage): number {
  const headerValue = request.headers["last-event-id"];
  const fromHeader = Array.isArray(headerValue) ? headerValue[0] : headerValue;
  const url = new URL(request.url ?? "/", "ws://localhost");
  const raw = url.searchParams.get("afterEventId") ?? fromHeader ?? "0";
  const value = Number(raw);
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function defaultProjectRoots(): string[] {
  const fromEnv = process.env.BRIDGE_PROJECT_ROOTS?.split(path.delimiter)
    .map((entry) => entry.trim())
    .filter(Boolean);
  if (fromEnv && fromEnv.length > 0) {
    return fromEnv;
  }

  const home = homedir();
  return [
    process.cwd(),
    path.join(home, "Documents"),
    path.join(home, "Developer"),
    path.join(home, "Projects")
  ].filter((root) => existsSync(root));
}

function normalizeProjectRoots(roots: string[]): string[] {
  return [...new Set(roots.map(normalizeAbsolutePath).filter((root): root is string => Boolean(root)))];
}

function normalizeAbsolutePath(value: string | undefined): string | null {
  if (!value || typeof value !== "string") {
    return null;
  }
  const expanded = value.startsWith("~/") ? path.join(homedir(), value.slice(2)) : value;
  if (!path.isAbsolute(expanded)) {
    return null;
  }
  return path.resolve(expanded);
}

function isPathInside(root: string, candidate: string): boolean {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function safeProjectName(value: unknown): string {
  if (typeof value !== "string") {
    throw new Error("Project name must be a string.");
  }
  const name = value.trim().replace(/\s+/g, " ");
  if (!name || name === "." || name === ".." || name.includes("/") || name.includes("\0") || name.includes("..")) {
    throw new Error("Project name cannot be empty or contain path separators.");
  }
  return name.slice(0, 80);
}

function safeAttachmentFilename(value: string): string {
  const base = path.basename(value).trim();
  const cleaned = base.replace(/[^\w .@()+\-]/g, "-").replace(/\s+/g, " ").slice(0, 96);
  if (!cleaned || cleaned === "." || cleaned === "..") {
    return "attachment";
  }
  return cleaned;
}

function isMobileAttachment(value: unknown): value is MobileAttachment {
  return (
    isRecord(value) &&
    (value.kind === "image" || value.kind === "file") &&
    typeof value.filename === "string" &&
    typeof value.dataBase64 === "string"
  );
}

function timestampForFilename(): string {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "").replace("T", "-");
}

function chatSummaryFromThread(thread: Record<string, unknown>): JsonObject {
  const id = typeof thread.id === "string" ? thread.id : "";
  const name = typeof thread.name === "string" && thread.name.trim() ? thread.name.trim() : null;
  const preview = typeof thread.preview === "string" ? thread.preview : "";
  const cwd = typeof thread.cwd === "string" ? thread.cwd : "";
  return {
    id,
    title: name ?? (preview.slice(0, 80) || path.basename(cwd) || id),
    preview,
    cwd,
    updatedAt: typeof thread.updatedAt === "number" ? thread.updatedAt : undefined,
    createdAt: typeof thread.createdAt === "number" ? thread.createdAt : undefined,
    status: asJsonValue(thread.status),
    source: typeof thread.source === "string" ? thread.source : undefined
  };
}

function resumeResultForMobile(result: JsonValue, thread: Record<string, unknown> | null): JsonObject {
  const source = isRecord(result) ? result : {};
  const sourceThread = thread ?? (isRecord(source.thread) ? source.thread : null);
  return {
    thread: sourceThread ? asJsonValue(threadForMobile(sourceThread)) : undefined,
    model: typeof source.model === "string" ? source.model : undefined,
    modelProvider: typeof source.modelProvider === "string" ? source.modelProvider : undefined,
    serviceTier: asJsonValue(source.serviceTier),
    cwd: typeof source.cwd === "string" ? source.cwd : sourceThread && typeof sourceThread.cwd === "string" ? sourceThread.cwd : undefined,
    instructionSources: asJsonValue(source.instructionSources),
    approvalPolicy: asJsonValue(source.approvalPolicy),
    approvalsReviewer: asJsonValue(source.approvalsReviewer),
    sandbox: asJsonValue(source.sandbox),
    permissionProfile: asJsonValue(source.permissionProfile),
    reasoningEffort: asJsonValue(source.reasoningEffort)
  };
}

function threadForMobile(thread: Record<string, unknown>): JsonObject {
  return {
    ...chatSummaryFromThread(thread),
    forkedFromId: asJsonValue(thread.forkedFromId),
    ephemeral: typeof thread.ephemeral === "boolean" ? thread.ephemeral : undefined,
    modelProvider: typeof thread.modelProvider === "string" ? thread.modelProvider : undefined,
    cliVersion: typeof thread.cliVersion === "string" ? thread.cliVersion : undefined,
    turnCount: Array.isArray(thread.turns) ? thread.turns.length : 0
  };
}

function turnForMobile(turn: Record<string, unknown>): JsonObject {
  return {
    id: typeof turn.id === "string" ? turn.id : undefined,
    status: typeof turn.status === "string" ? turn.status : undefined,
    error: asJsonValue(turn.error),
    startedAt: typeof turn.startedAt === "number" ? turn.startedAt : undefined,
    completedAt: typeof turn.completedAt === "number" ? turn.completedAt : undefined,
    durationMs: typeof turn.durationMs === "number" ? turn.durationMs : undefined
  };
}

function mobileSafeCodexParams(method: string, params: unknown): JsonValue {
  if (!isRecord(params)) {
    return asJsonValue(params);
  }
  if (method === "thread/started" && isRecord(params.thread)) {
    return asJsonValue({
      ...params,
      thread: threadForMobile(params.thread)
    });
  }
  if (method === "turn/completed" && isRecord(params.turn)) {
    return asJsonValue({
      ...params,
      turn: turnForMobile(params.turn)
    });
  }
  return asJsonValue(params);
}

type TranscriptResult = {
  entries: JsonValue[];
  truncation: JsonObject;
};

type TranscriptOptions = {
  entryLimit: number;
  byteLimit: number;
};

type TranscriptEntryBuild = {
  entry: JsonObject;
  textTruncated: boolean;
};

type TranscriptAttachment = {
  kind: "image" | "file";
  filename: string;
  path?: string;
  mimeType?: string;
  byteCount?: number;
  previewDataBase64?: string;
};

function emptyTranscriptResult(): TranscriptResult {
  return {
    entries: [],
    truncation: {
      truncated: false,
      originalEntryCount: 0,
      returnedEntryCount: 0,
      droppedEntries: 0,
      textTruncatedEntries: 0,
      entryLimit: DEFAULT_CHAT_TRANSCRIPT_ENTRY_LIMIT,
      byteLimit: DEFAULT_CHAT_TRANSCRIPT_BYTE_LIMIT
    }
  };
}

async function transcriptFromThread(thread: Record<string, unknown>, options: TranscriptOptions): Promise<TranscriptResult> {
  const threadId = typeof thread.id === "string" ? thread.id : undefined;
  const turns = Array.isArray(thread.turns) ? thread.turns.filter(isRecord) : [];
  return transcriptFromTurns(turns, threadId, options, false);
}

async function transcriptFromTurns(
  turns: Array<Record<string, unknown>>,
  threadId: string | undefined,
  options: TranscriptOptions,
  newestFirst: boolean
): Promise<TranscriptResult> {
  const orderedTurns = newestFirst ? [...turns].reverse() : turns;
  const entries: JsonObject[] = [];
  let textTruncatedEntries = 0;
  for (const turn of orderedTurns) {
    const turnId = typeof turn.id === "string" ? turn.id : undefined;
    const createdAt = typeof turn.startedAt === "number" ? turn.startedAt : undefined;
    const items = Array.isArray(turn.items) ? turn.items.filter(isRecord) : [];
    for (const item of items) {
      const built = transcriptEntryFromItem(item, threadId, turnId, createdAt, DEFAULT_CHAT_TRANSCRIPT_ENTRY_TEXT_BYTE_LIMIT);
      const entry = built?.entry;
      if (entry) {
        entries.push(entry);
        if (built.textTruncated) {
          textTruncatedEntries += 1;
        }
      }
    }
  }
  await hydrateTranscriptAttachmentPreviews(entries);
  const limited = limitTranscriptEntries(entries, options);
  const droppedEntries = entries.length - limited.length;
  return {
    entries: limited.map((entry) => asJsonValue(entry)),
    truncation: {
      truncated: droppedEntries > 0 || textTruncatedEntries > 0,
      originalEntryCount: entries.length,
      returnedEntryCount: limited.length,
      droppedEntries,
      textTruncatedEntries,
      entryLimit: options.entryLimit,
      byteLimit: options.byteLimit
    }
  };
}

function transcriptEntryFromItem(
  item: Record<string, unknown>,
  threadId: string | undefined,
  turnId: string | undefined,
  createdAt: number | undefined,
  textByteLimit: number
): TranscriptEntryBuild | null {
  const type = item.type;
  const id = typeof item.id === "string" ? item.id : undefined;
  if (type === "userMessage") {
    const content = Array.isArray(item.content) ? item.content.filter(isRecord) : [];
    const text = truncateUtf8(userInputText(content), textByteLimit);
    const attachments = transcriptAttachmentsFromUserInput(content);
    return text.text || attachments.length > 0
      ? {
          entry: {
            role: "user",
            text: text.text,
            itemId: id,
            threadId,
            turnId,
            createdAt,
            attachments: attachments.length > 0 ? asJsonValue(attachments) : undefined
          },
          textTruncated: text.truncated
        }
      : null;
  }
  if (type === "agentMessage" && typeof item.text === "string") {
    const text = truncateUtf8(item.text, textByteLimit);
    return { entry: { role: "assistant", text: text.text, itemId: id, threadId, turnId, createdAt }, textTruncated: text.truncated };
  }
  if (type === "commandExecution" && typeof item.command === "string") {
    const output = typeof item.aggregatedOutput === "string" && item.aggregatedOutput ? `\n${item.aggregatedOutput}` : "";
    const text = truncateUtf8(`$ ${item.command}${output}`, textByteLimit);
    return { entry: { role: "system", text: text.text, itemId: id, threadId, turnId, createdAt }, textTruncated: text.truncated };
  }
  if (type === "fileChange") {
    return { entry: { role: "system", text: "File change", itemId: id, threadId, turnId, createdAt }, textTruncated: false };
  }
  if (type === "mcpToolCall" && typeof item.tool === "string") {
    return { entry: { role: "system", text: `Tool: ${item.tool}`, itemId: id, threadId, turnId, createdAt }, textTruncated: false };
  }
  if (type === "collabAgentToolCall") {
    const tool = typeof item.tool === "string" ? item.tool : "subagent";
    const status = typeof item.status === "string" ? item.status : "updated";
    const receivers = Array.isArray(item.receiverThreadIds)
      ? item.receiverThreadIds.filter((value): value is string => typeof value === "string")
      : [];
    const suffix = receivers.length > 0 ? ` (${receivers.join(", ")})` : "";
    return { entry: { role: "system", text: `Subagent ${tool}: ${status}${suffix}`, itemId: id, threadId, turnId, createdAt }, textTruncated: false };
  }
  if (type === "contextCompaction") {
    return { entry: { role: "system", text: "Context compacted", itemId: id, threadId, turnId, createdAt }, textTruncated: false };
  }
  return null;
}

function limitTranscriptEntries(entries: JsonObject[], options: TranscriptOptions): JsonObject[] {
  const candidates = entries.slice(-options.entryLimit);
  const selected: JsonObject[] = [];
  let bytes = 2;
  for (let index = candidates.length - 1; index >= 0; index -= 1) {
    const entry = candidates[index];
    const entryBytes = Buffer.byteLength(JSON.stringify(entry), "utf8") + 1;
    if (selected.length > 0 && bytes + entryBytes > options.byteLimit) {
      break;
    }
    selected.push(entry);
    bytes += entryBytes;
  }
  return selected.reverse();
}

function truncateUtf8(text: string, maxBytes: number): { text: string; truncated: boolean } {
  if (Buffer.byteLength(text, "utf8") <= maxBytes) {
    return { text, truncated: false };
  }
  const suffix = "\n[truncated]";
  const suffixBytes = Buffer.byteLength(suffix, "utf8");
  const targetBytes = Math.max(0, maxBytes - suffixBytes);
  let low = 0;
  let high = text.length;
  while (low < high) {
    const midpoint = Math.floor((low + high + 1) / 2);
    if (Buffer.byteLength(text.slice(0, midpoint), "utf8") <= targetBytes) {
      low = midpoint;
    } else {
      high = midpoint - 1;
    }
  }
  return { text: `${text.slice(0, low).trimEnd()}${suffix}`, truncated: true };
}

function transcriptAttachmentsFromUserInput(content: Array<Record<string, unknown>>): TranscriptAttachment[] {
  const attachments: TranscriptAttachment[] = [];
  for (const input of content) {
    if (input.type === "localImage" && typeof input.path === "string") {
      attachments.push({
        kind: "image",
        filename: path.basename(input.path) || "image",
        path: input.path
      });
    } else if (input.type === "image" && typeof input.url === "string") {
      attachments.push({
        kind: "image",
        filename: path.basename(new URL(input.url, "file:///").pathname) || "image",
        path: input.url
      });
    } else if (input.type === "text" && typeof input.text === "string") {
      attachments.push(...parseAttachmentLines(input.text));
    }
  }
  return dedupeTranscriptAttachments(attachments);
}

function parseAttachmentLines(text: string): TranscriptAttachment[] {
  const attachments: TranscriptAttachment[] = [];
  const pattern = /^-\s+(.+?):\s+(.+?)\s+\((image|file)(?:,\s*([^,()]+))?(?:,\s*(\d+)\s+bytes)?\)$/gm;
  for (const match of text.matchAll(pattern)) {
    const filename = safeAttachmentFilename(match[1] ?? "attachment");
    const attachmentPath = match[2]?.trim();
    const kind = match[3] === "image" ? "image" : "file";
    if (!attachmentPath) {
      continue;
    }
    attachments.push({
      kind,
      filename,
      path: attachmentPath,
      mimeType: match[4]?.trim(),
      byteCount: match[5] ? Number(match[5]) : undefined
    });
  }
  return attachments;
}

function dedupeTranscriptAttachments(attachments: TranscriptAttachment[]): TranscriptAttachment[] {
  const seen = new Set<string>();
  const result: TranscriptAttachment[] = [];
  for (const attachment of attachments) {
    const key = `${attachment.kind}:${attachment.path ?? attachment.filename}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(attachment);
  }
  return result;
}

async function hydrateTranscriptAttachmentPreviews(entries: JsonObject[]): Promise<void> {
  for (const entry of entries) {
    if (!Array.isArray(entry.attachments)) {
      continue;
    }
    const attachments = entry.attachments.filter(isRecord) as Array<Record<string, unknown>>;
    for (const attachment of attachments) {
      if (attachment.kind !== "image" || typeof attachment.path !== "string" || typeof attachment.previewDataBase64 === "string") {
        continue;
      }
      const preview = await readSmallImagePreview(attachment.path);
      if (preview) {
        attachment.previewDataBase64 = preview.dataBase64;
        attachment.mimeType = typeof attachment.mimeType === "string" ? attachment.mimeType : preview.mimeType;
        attachment.byteCount = typeof attachment.byteCount === "number" ? attachment.byteCount : preview.byteCount;
      }
    }
  }
}

async function readSmallImagePreview(imagePath: string): Promise<{ dataBase64: string; mimeType: string; byteCount: number } | null> {
  const normalized = normalizeAbsolutePath(imagePath);
  if (!normalized) {
    return null;
  }
  try {
    const info = await stat(normalized);
    if (!info.isFile() || info.size > DEFAULT_CHAT_ATTACHMENT_PREVIEW_BYTE_LIMIT) {
      return null;
    }
    const data = await readFile(normalized);
    return {
      dataBase64: data.toString("base64"),
      mimeType: mimeTypeFromFilename(normalized) ?? "image/*",
      byteCount: data.byteLength
    };
  } catch {
    return null;
  }
}

function mimeTypeFromFilename(filename: string): string | null {
  const ext = path.extname(filename).toLowerCase();
  if (ext === ".png") return "image/png";
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".gif") return "image/gif";
  if (ext === ".webp") return "image/webp";
  if (ext === ".heic") return "image/heic";
  if (ext === ".pdf") return "application/pdf";
  if (ext === ".txt") return "text/plain";
  return null;
}

function userInputText(content: Array<Record<string, unknown>>): string {
  const parts: string[] = [];
  for (const input of content) {
    if (input.type === "text" && typeof input.text === "string") {
      parts.push(input.text);
    } else if (input.type === "localImage" && typeof input.path === "string") {
      parts.push(`[image: ${input.path}]`);
    } else if (input.type === "image" && typeof input.url === "string") {
      parts.push(`[image: ${input.url}]`);
    } else if (typeof input.path === "string") {
      parts.push(`[${String(input.type)}: ${input.path}]`);
    }
  }
  return parts.join("\n").trim();
}

function threadContainsUserInput(thread: Record<string, unknown>, input: JsonValue[]): boolean {
  const inputRecords = input.filter(isRecord) as Array<Record<string, unknown>>;
  const targetText = userInputText(inputRecords);
  if (!targetText) {
    return false;
  }
  const turns = Array.isArray(thread.turns) ? thread.turns.filter(isRecord) : [];
  for (const turn of turns) {
    const items = Array.isArray(turn.items) ? turn.items.filter(isRecord) : [];
    for (const item of items) {
      if (item.type !== "userMessage") {
        continue;
      }
      const content = Array.isArray(item.content) ? item.content.filter(isRecord) : [];
      if (userInputText(content) === targetText) {
        return true;
      }
    }
  }
  return false;
}

function responseItemsFromUserInput(input: JsonValue[]): JsonValue[] {
  const content = responseContentFromUserInput(input.filter(isRecord) as Array<Record<string, unknown>>);
  if (content.length === 0) {
    return [];
  }
  return [
    {
      type: "message",
      role: "user",
      content
    }
  ];
}

function responseContentFromUserInput(input: Array<Record<string, unknown>>): JsonValue[] {
  const content: JsonValue[] = [];
  for (const item of input) {
    if (item.type === "text" && typeof item.text === "string" && item.text.trim()) {
      content.push({ type: "input_text", text: item.text });
    } else if (item.type === "localImage" && typeof item.path === "string") {
      content.push({ type: "input_text", text: `[image: ${item.path}]` });
    } else if (item.type === "image" && typeof item.url === "string") {
      content.push({ type: "input_text", text: `[image: ${item.url}]` });
    } else if (typeof item.path === "string") {
      content.push({ type: "input_text", text: `[${String(item.type)}: ${item.path}]` });
    }
  }
  return content;
}

async function projectSummary(projectPath: string, source: ProjectSource): Promise<ProjectSummary | null> {
  try {
    const info = await stat(projectPath);
    if (!info.isDirectory()) {
      return null;
    }
    return {
      path: projectPath,
      name: path.basename(projectPath) || projectPath,
      source,
      updatedAt: Math.floor(info.mtimeMs / 1000)
    };
  } catch {
    return null;
  }
}

function dedupeProjects(projects: ProjectSummary[]): ProjectSummary[] {
  const byPath = new Map<string, ProjectSummary>();
  for (const project of projects) {
    const previous = byPath.get(project.path);
    if (!previous || projectSourceRank(project.source) < projectSourceRank(previous.source)) {
      byPath.set(project.path, project);
    }
  }
  return [...byPath.values()].sort((left, right) => {
    const rank = projectSourceRank(left.source) - projectSourceRank(right.source);
    if (rank !== 0) {
      return rank;
    }
    return (right.updatedAt ?? 0) - (left.updatedAt ?? 0) || left.name.localeCompare(right.name);
  });
}

function projectSourceRank(source: ProjectSource): number {
  if (source === "recent") {
    return 0;
  }
  if (source === "root") {
    return 1;
  }
  if (source === "created") {
    return 2;
  }
  return 3;
}

function safeSandbox(value: unknown): SafeSandbox {
  if (value === "workspace-write") {
    return "workspace-write";
  }
  return "read-only";
}

function safeApprovalPolicy(value: unknown): SafeApprovalPolicy {
  if (value === "untrusted") {
    return "untrusted";
  }
  if (value === "on-failure") {
    return "on-failure";
  }
  return "on-request";
}

function safeReasoningEffort(value: unknown): ReasoningEffort | undefined {
  if (
    value === "none" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh"
  ) {
    return value;
  }
  return undefined;
}

function safeReasoningSummary(value: unknown): ReasoningSummary | undefined {
  if (value === "auto" || value === "concise" || value === "detailed" || value === "none") {
    return value;
  }
  return undefined;
}

function safeVerbosity(value: unknown): Verbosity | undefined {
  if (value === "low" || value === "medium" || value === "high") {
    return value;
  }
  return undefined;
}

function safeSubagentRole(value: unknown): SubagentRole {
  if (value === "explorer" || value === "worker" || value === "reviewer") {
    return value;
  }
  return "default";
}

function configFromMobileSettings(message: {
  reasoningEffort?: unknown;
  reasoningSummary?: unknown;
  verbosity?: unknown;
  autoCompact?: unknown;
  autoCompactTokenLimit?: unknown;
}): JsonObject | undefined {
  const config: JsonObject = {};
  const effort = safeReasoningEffort(message.reasoningEffort);
  const summary = safeReasoningSummary(message.reasoningSummary);
  const verbosity = safeVerbosity(message.verbosity);
  if (effort) {
    config.model_reasoning_effort = effort;
  }
  if (summary) {
    config.model_reasoning_summary = summary;
  }
  if (verbosity) {
    config.model_verbosity = verbosity;
  }
  if (message.autoCompact === true) {
    config.model_auto_compact_token_limit = boundedInteger(message.autoCompactTokenLimit, 4096, 2_000_000, 120_000);
  }
  return Object.keys(config).length > 0 ? config : undefined;
}

function sandboxPolicyFromMode(mode: SafeSandbox, cwd: string | undefined): JsonObject {
  if (mode === "workspace-write") {
    const root = normalizeAbsolutePath(cwd);
    if (!root) {
      throw new Error("workspace-write turns require an absolute project workspace.");
    }
    return {
      type: "workspaceWrite",
      writableRoots: [root],
      readOnlyAccess: { type: "fullAccess" },
      networkAccess: false,
      excludeTmpdirEnvVar: false,
      excludeSlashTmp: false
    };
  }

  return {
    type: "readOnly",
    access: { type: "fullAccess" },
    networkAccess: false
  };
}

function subagentPrompt(role: SubagentRole, prompt: string): string {
  const roleLabel =
    role === "explorer"
      ? "explorer"
      : role === "worker"
        ? "worker"
        : role === "reviewer"
          ? "reviewer"
          : "default";
  return [
    `You are a maludex ${roleLabel} subagent running in a forked Codex thread.`,
    "Work independently, keep the parent task in mind, and report concise findings or changed file paths in your final answer.",
    "Do not change permissions beyond the current mobile-selected sandbox and approval policy.",
    "Task:",
    prompt.trim()
  ].join("\n\n");
}

function boundedInteger(value: unknown, min: number, max: number, fallback: number): number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max ? value : fallback;
}

function approvalResult(
  method: string,
  decision: ApprovalDecision,
  permissions?: JsonValue,
  scope?: "turn" | "session"
): JsonValue {
  if (method === "execCommandApproval" || method === "applyPatchApproval") {
    const legacy = {
      accept: "approved",
      acceptForSession: "approved_for_session",
      decline: "denied",
      cancel: "abort"
    } satisfies Record<ApprovalDecision, string>;
    return { decision: legacy[decision] };
  }

  if (method === "item/permissions/requestApproval") {
    return {
      permissions: decision === "accept" || decision === "acceptForSession" ? permissions ?? {} : {},
      scope: scope ?? (decision === "acceptForSession" ? "session" : "turn"),
      strictAutoReview: true
    };
  }

  return { decision };
}

function turnIdFromStartResult(result: JsonValue): string | null {
  if (!isRecord(result) || !isRecord(result.turn)) {
    return null;
  }
  return typeof result.turn.id === "string" ? result.turn.id : null;
}

function threadIdFromThreadResult(result: JsonValue): string | null {
  if (!isRecord(result) || !isRecord(result.thread)) {
    return null;
  }
  return typeof result.thread.id === "string" ? result.thread.id : null;
}

function firstMapKey(map: Map<string, unknown>): string | undefined {
  return map.keys().next().value;
}

function publicQueueItem(item: QueuedPromptTurn): JsonObject {
  return {
    id: item.id,
    threadId: item.threadId,
    promptPreview: item.promptPreview,
    promptBytes: item.promptBytes,
    attachmentCount: item.attachmentCount,
    createdAt: item.createdAt
  };
}

function promptQueueStoreFromJson(value: unknown): Map<string, QueuedPromptTurn[]> {
  if (!isRecord(value) || !Array.isArray(value.queues)) {
    throw new Error("Prompt queue state must contain a queues array.");
  }

  const queues = new Map<string, QueuedPromptTurn[]>();
  for (const rawQueue of value.queues) {
    if (!isRecord(rawQueue) || typeof rawQueue.threadId !== "string" || !Array.isArray(rawQueue.items)) {
      continue;
    }
    const threadId = rawQueue.threadId;
    const items = rawQueue.items
      .map((item) => queuedPromptTurnFromJson(item, threadId))
      .filter((item): item is QueuedPromptTurn => item !== null);
    if (items.length > 0) {
      queues.set(threadId, items.slice(0, MAX_PROMPT_QUEUE_ITEMS));
    }
  }
  return queues;
}

function queuedPromptTurnFromJson(value: unknown, fallbackThreadId: string): QueuedPromptTurn | null {
  if (!isRecord(value)
    || typeof value.id !== "string"
    || !Array.isArray(value.input)
    || !isRecord(value.params)
    || !isRecord(value.authoredTurn)
    || !Array.isArray(value.authoredTurn.input)) {
    return null;
  }

  const threadId = typeof value.threadId === "string" && value.threadId ? value.threadId : fallbackThreadId;
  const authoredThreadId =
    typeof value.authoredTurn.threadId === "string" && value.authoredTurn.threadId ? value.authoredTurn.threadId : threadId;
  const authoredTurn: MobileAuthoredTurn = {
    threadId: authoredThreadId,
    turnId: typeof value.authoredTurn.turnId === "string" ? value.authoredTurn.turnId : undefined,
    input: value.authoredTurn.input as JsonValue[]
  };
  return {
    id: value.id,
    threadId,
    input: value.input as JsonValue[],
    params: value.params as JsonObject,
    authoredTurn,
    sandbox: safeSandbox(value.sandbox),
    promptPreview: typeof value.promptPreview === "string" ? value.promptPreview : "Queued prompt",
    promptBytes: typeof value.promptBytes === "number" && Number.isFinite(value.promptBytes) ? value.promptBytes : 0,
    attachmentCount: typeof value.attachmentCount === "number" && Number.isFinite(value.attachmentCount) ? value.attachmentCount : 0,
    createdAt: typeof value.createdAt === "string" ? value.createdAt : new Date().toISOString()
  };
}

function numericQueueId(id: string): number {
  const match = /^queue-(\d+)$/.exec(id);
  return match ? Number(match[1]) : 0;
}

function promptPreview(prompt: string): string {
  const normalized = prompt.trim().replace(/\s+/g, " ");
  if (normalized.length <= 120) {
    return normalized;
  }
  return `${normalized.slice(0, 117)}...`;
}

function mobileTurnKey(threadId: string, turnId: string): string {
  return `${threadId}:${turnId}`;
}

function messageId(value: unknown): string | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  return typeof value.id === "string" ? value.id : undefined;
}
