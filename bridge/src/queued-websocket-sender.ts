import type { JsonObject, JsonValue } from "./types.js";

export type WebSocketLike = {
  readyState: number;
  bufferedAmount: number;
  send(payload: string, callback?: (error?: Error) => void): void;
  close(code?: number, reason?: string): void;
};

export type QueuedWebSocketSenderOptions = {
  openState?: number;
  highWatermarkBytes?: number;
  maxQueuedMessages?: number;
  flushIntervalMs?: number;
};

export class QueuedWebSocketSender {
  private readonly openState: number;
  private readonly highWatermarkBytes: number;
  private readonly maxQueuedMessages: number;
  private readonly flushIntervalMs: number;
  private readonly queue: string[] = [];
  private flushTimer: NodeJS.Timeout | null = null;
  private sending = false;
  private closed = false;

  constructor(
    private readonly socket: WebSocketLike,
    options: QueuedWebSocketSenderOptions = {}
  ) {
    this.openState = options.openState ?? 1;
    this.highWatermarkBytes = options.highWatermarkBytes ?? 1024 * 1024;
    this.maxQueuedMessages = options.maxQueuedMessages ?? 256;
    this.flushIntervalMs = options.flushIntervalMs ?? 50;
  }

  send(message: JsonValue | JsonObject): boolean {
    if (this.closed || this.socket.readyState !== this.openState) {
      return false;
    }

    if (this.queue.length >= this.maxQueuedMessages) {
      this.closeSlowClient();
      return false;
    }

    this.queue.push(JSON.stringify(message));
    this.flush();
    return !this.closed;
  }

  stop(): void {
    this.closed = true;
    this.queue.length = 0;
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
  }

  private flush(): void {
    if (this.closed || this.sending || this.socket.readyState !== this.openState) {
      return;
    }

    if (this.socket.bufferedAmount > this.highWatermarkBytes) {
      this.scheduleFlush();
      return;
    }

    const payload = this.queue.shift();
    if (!payload) {
      return;
    }

    this.sending = true;
    this.socket.send(payload, (error?: Error) => {
      this.sending = false;
      if (error) {
        this.closeSlowClient();
        return;
      }
      this.flush();
    });
  }

  private scheduleFlush(): void {
    if (this.flushTimer || this.closed) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flush();
    }, this.flushIntervalMs);
    this.flushTimer.unref?.();
  }

  private closeSlowClient(): void {
    this.closed = true;
    this.queue.length = 0;
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this.socket.close(1013, "client too slow");
  }
}
