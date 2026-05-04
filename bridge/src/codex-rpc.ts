import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
import type { Logger } from "./logger.js";
import { asJsonValue, isRecord, type CodexMessage, type JsonRpcId, type JsonValue } from "./types.js";

type PendingRequest = {
  method: string;
  resolve: (value: JsonValue) => void;
  reject: (reason: Error) => void;
  timer: NodeJS.Timeout;
};

export type CodexRpcClientOptions = {
  command?: string;
  args?: string[];
  env?: NodeJS.ProcessEnv;
  logger: Logger;
  requestTimeoutMs?: number;
};

export class CodexRpcClient extends EventEmitter {
  private readonly command: string;
  private readonly args: string[];
  private readonly env?: NodeJS.ProcessEnv;
  private readonly logger: Logger;
  private readonly requestTimeoutMs: number;
  private child: ChildProcessWithoutNullStreams | null = null;
  private nextId = 1;
  private readonly pending = new Map<JsonRpcId, PendingRequest>();

  constructor(options: CodexRpcClientOptions) {
    super();
    this.command = options.command ?? "codex";
    this.args = options.args ?? ["app-server", "--listen", "stdio://"];
    this.env = options.env;
    this.logger = options.logger;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 120000;
  }

  async start(): Promise<void> {
    if (this.child) {
      return;
    }

    this.child = spawn(this.command, this.args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, ...this.env }
    });

    this.child.once("exit", (code, signal) => {
      this.logger.warn("codex.exit", { code, signal });
      this.rejectAll(new Error(`codex app-server exited (${code ?? signal ?? "unknown"})`));
      this.child = null;
    });
    this.child.once("error", (error) => {
      this.logger.error("codex.process_error", { message: error.message });
      this.rejectAll(error);
    });

    const stdout = createInterface({ input: this.child.stdout });
    stdout.on("line", (line) => this.handleLine(line));

    const stderr = createInterface({ input: this.child.stderr });
    stderr.on("line", (line) => {
      this.logger.warn("codex.stderr", { bytes: Buffer.byteLength(line, "utf8") });
    });

    await this.request("initialize", {
      clientInfo: {
        name: "maludex-bridge",
        title: "maludex bridge",
        version: "0.1.0"
      },
      capabilities: {
        experimentalApi: true
      }
    });
    this.notify("initialized");
  }

  async stop(): Promise<void> {
    if (!this.child) {
      return;
    }

    const child = this.child;
    this.child = null;
    child.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        resolve();
      }, 2000);
      child.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  isRunning(): boolean {
    return this.child !== null;
  }

  request(method: string, params?: JsonValue): Promise<JsonValue> {
    const id = this.nextId++;
    const message = params === undefined ? { id, method } : { id, method, params };
    this.write(message);
    this.logger.info("codex.request", { id, method });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`codex request timed out: ${method}`));
      }, this.requestTimeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
    });
  }

  notify(method: string, params?: JsonValue): void {
    const message = params === undefined ? { method } : { method, params };
    this.write(message);
    this.logger.info("codex.notification.sent", { method });
  }

  respond(id: JsonRpcId, result: JsonValue): void {
    this.write({ id, result });
    this.logger.info("codex.response.sent", { id });
  }

  private write(message: CodexMessage): void {
    if (!this.child) {
      throw new Error("codex app-server is not running");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private handleLine(line: string): void {
    if (!line.trim()) {
      return;
    }

    let message: unknown;
    try {
      message = JSON.parse(line);
    } catch (error) {
      this.logger.warn("codex.invalid_json", { bytes: Buffer.byteLength(line, "utf8") });
      return;
    }

    if (!isRecord(message)) {
      this.logger.warn("codex.invalid_message", { shape: typeof message });
      return;
    }

    if ("method" in message && typeof message.method === "string" && "id" in message) {
      this.logger.info("codex.server_request", { id: message.id, method: message.method });
      this.emit("serverRequest", asJsonValue(message));
      return;
    }

    if ("method" in message && typeof message.method === "string") {
      this.logger.info("codex.notification.received", { method: message.method });
      this.emit("notification", asJsonValue(message));
      return;
    }

    if ("id" in message && ("result" in message || "error" in message)) {
      this.handleResponse(message);
      return;
    }

    this.logger.warn("codex.unknown_message", { keys: Object.keys(message) });
  }

  private handleResponse(message: Record<string, unknown>): void {
    const id = message.id as JsonRpcId;
    const pending = this.pending.get(id);
    if (!pending) {
      this.logger.warn("codex.unmatched_response", { id });
      return;
    }

    clearTimeout(pending.timer);
    this.pending.delete(id);

    if ("error" in message && isRecord(message.error)) {
      const code = typeof message.error.code === "number" ? message.error.code : -32000;
      const text = typeof message.error.message === "string" ? message.error.message : "Codex JSON-RPC error";
      pending.reject(new Error(`${pending.method} failed (${code}): ${text}`));
      return;
    }

    pending.resolve(asJsonValue(message.result ?? null));
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
