export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue | undefined };
export type JsonRpcId = string | number;

export type JsonRpcRequest = {
  id: JsonRpcId;
  method: string;
  params?: JsonValue;
};

export type JsonRpcNotification = {
  method: string;
  params?: JsonValue;
};

export type JsonRpcResponse = {
  id: JsonRpcId;
  result?: JsonValue;
  error?: {
    code: number;
    message: string;
    data?: JsonValue;
  };
};

export type CodexMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

export type SafeSandbox = "read-only" | "workspace-write";
export type SafeApprovalPolicy = "untrusted" | "on-failure" | "on-request";
export type ReasoningEffort = "none" | "minimal" | "low" | "medium" | "high" | "xhigh";
export type ReasoningSummary = "auto" | "concise" | "detailed" | "none";
export type Verbosity = "low" | "medium" | "high";
export type SubagentRole = "default" | "explorer" | "worker" | "reviewer";
export type ApprovalDecision = "accept" | "acceptForSession" | "decline" | "cancel";
export type MobileAttachmentKind = "image" | "file";

export type MobileAttachment = {
  kind: MobileAttachmentKind;
  filename: string;
  mimeType?: string;
  dataBase64: string;
};

export type MobileMessage =
  | {
      id?: string;
      type: "thread.start";
      cwd?: string;
      model?: string;
      approvalPolicy?: SafeApprovalPolicy;
      sandbox?: SafeSandbox;
      reasoningEffort?: ReasoningEffort;
      reasoningSummary?: ReasoningSummary;
      verbosity?: Verbosity;
      autoCompact?: boolean;
      autoCompactTokenLimit?: number;
      ephemeral?: boolean;
    }
  | {
      id?: string;
      type: "turn.start" | "turn.send";
      threadId: string;
      prompt: string;
      cwd?: string;
      model?: string;
      approvalPolicy?: SafeApprovalPolicy;
      sandbox?: SafeSandbox;
      reasoningEffort?: ReasoningEffort;
      reasoningSummary?: ReasoningSummary;
      attachments?: MobileAttachment[];
    }
  | {
      id?: string;
      type: "turn.stop";
      threadId?: string;
      turnId?: string;
    }
  | {
      id?: string;
      type: "turn.steer";
      threadId: string;
      turnId?: string;
      prompt: string;
      cwd?: string;
      attachments?: MobileAttachment[];
    }
  | {
      id?: string;
      type: "queue.list";
      threadId?: string;
    }
  | {
      id?: string;
      type: "queue.move";
      itemId: string;
      threadId?: string;
      toIndex: number;
    }
  | {
      id?: string;
      type: "queue.cancel";
      itemId: string;
      threadId?: string;
    }
  | {
      id?: string;
      type: "approval.respond";
      approvalId: string;
      decision?: ApprovalDecision;
      result?: JsonValue;
      permissions?: JsonValue;
      scope?: "turn" | "session";
    }
  | {
      id?: string;
      type: "ping";
    }
  | {
      id?: string;
      type: "bridge.status";
    }
  | {
      id?: string;
      type: "project.list";
    }
  | {
      id?: string;
      type: "project.create";
      root: string;
      name: string;
    }
  | {
      id?: string;
      type: "model.list";
    }
  | {
      id?: string;
      type: "chat.list";
      limit?: number;
      cursor?: string;
      searchTerm?: string;
    }
  | {
      id?: string;
      type: "chat.open";
      threadId: string;
      model?: string;
      approvalPolicy?: SafeApprovalPolicy;
      sandbox?: SafeSandbox;
      reasoningEffort?: ReasoningEffort;
      reasoningSummary?: ReasoningSummary;
      verbosity?: Verbosity;
      autoCompact?: boolean;
      autoCompactTokenLimit?: number;
      transcriptLimit?: number;
      transcriptByteLimit?: number;
      turnLimit?: number;
    }
  | {
      id?: string;
      type: "chat.history";
      threadId: string;
      cursor?: string;
      limit?: number;
      transcriptByteLimit?: number;
    }
  | {
      id?: string;
      type: "thread.compact";
      threadId: string;
    }
  | {
      id?: string;
      type: "subagent.start";
      threadId: string;
      prompt: string;
      cwd?: string;
      model?: string;
      role?: SubagentRole;
      approvalPolicy?: SafeApprovalPolicy;
      sandbox?: SafeSandbox;
      reasoningEffort?: ReasoningEffort;
      reasoningSummary?: ReasoningSummary;
    };

export type MobileResponse =
  | {
      type: "bridge.ready";
      protocolVersion: 1;
      minClientProtocolVersion: number;
      bridgeVersion: string;
      serverTime: string;
      lastEventId: number;
    }
  | {
      id?: string;
      type: "response";
      ok: true;
      result: JsonValue;
    }
  | {
      id?: string;
      type: "response";
      ok: false;
      error: {
        code: string;
        message: string;
      };
    }
  | {
      type: "codex.event";
      eventId: number;
      replayed?: boolean;
      method: string;
      params?: JsonValue;
    }
  | {
      type: "approval.requested";
      eventId: number;
      replayed?: boolean;
      approvalId: string;
      method: string;
      params?: JsonValue;
    };

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function asJsonValue(value: unknown): JsonValue {
  return value as JsonValue;
}
