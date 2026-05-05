import { createInterface } from "node:readline";
import { appendFileSync } from "node:fs";

const reportFile = process.env.MOCK_CODEX_REPORT_FILE;

function report(message) {
  if (!reportFile) {
    return;
  }
  appendFileSync(reportFile, `${JSON.stringify(message)}\n`, { mode: 0o600 });
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function sendApprovalRequest(message) {
  send({
    id: "approval-1",
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: message.params.threadId,
      turnId: "turn-1",
      itemId: "cmd-1",
      command: "npm test",
      cwd: process.cwd(),
      availableDecisions: ["accept", "decline", "cancel"]
    }
  });
}

function thread(overrides = {}) {
  return {
    id: "thread-1",
    forkedFromId: null,
    preview: "",
    ephemeral: false,
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    status: "idle",
    path: null,
    cwd: process.env.MOCK_CODEX_RECENT_CWD ?? process.cwd(),
    cliVersion: "mock",
    source: "app_server",
    agentNickname: null,
    agentRole: null,
    gitInfo: null,
    name: null,
    turns: [],
    ...overrides
  };
}

function turn(status = "running") {
  return {
    id: "turn-1",
    items: [],
    status,
    error: null,
    startedAt: 1,
    completedAt: null,
    durationMs: null
  };
}

function historyTurn() {
  if (process.env.MOCK_CODEX_ATTACHMENT_HISTORY === "1") {
    return {
      id: "history-turn-attachments",
      items: [
        {
          type: "userMessage",
          id: "user-attachments",
          content: [
            { type: "text", text: `첨부 확인\n\n첨부 파일:\n- notes.pdf: ${process.env.MOCK_CODEX_ATTACHMENT_FILE_PATH} (file, application/pdf, 5 bytes)`, text_elements: [] },
            { type: "localImage", path: process.env.MOCK_CODEX_ATTACHMENT_IMAGE_PATH }
          ]
        }
      ],
      status: "completed",
      error: null,
      startedAt: 1,
      completedAt: 2,
      durationMs: 1000
    };
  }

  return {
    id: "history-turn-1",
    items: [
      {
        type: "userMessage",
        id: "user-1",
        content: [{ type: "text", text: "이전에 내가 한 질문", text_elements: [] }]
      },
      {
        type: "agentMessage",
        id: "assistant-1",
        text: "이전에 Codex가 한 답변",
        phase: null,
        memoryCitation: null
      },
      {
        type: "commandExecution",
        id: "cmd-1",
        command: "ls",
        cwd: process.cwd(),
        processId: null,
        source: "agent",
        status: "completed",
        commandActions: [],
        aggregatedOutput: "README.md",
        exitCode: 0,
        durationMs: 10
      }
    ],
    status: "completed",
    error: null,
    startedAt: 1,
    completedAt: 2,
    durationMs: 1000
  };
}

function hugeHistoryTurns() {
  const repeated = "긴 기존 대화 내용 ".repeat(12000);
  return Array.from({ length: 30 }, (_, index) => ({
    id: `huge-turn-${index}`,
    items: [
      {
        type: "userMessage",
        id: `huge-user-${index}`,
        content: [{ type: "text", text: `${index}: ${repeated}`, text_elements: [] }]
      },
      {
        type: "agentMessage",
        id: `huge-assistant-${index}`,
        text: `${index}: ${repeated}`,
        phase: null,
        memoryCitation: null
      }
    ],
    status: "completed",
    error: null,
    startedAt: index + 1,
    completedAt: index + 2,
    durationMs: 1000
  }));
}

function pagedHistoryTurns() {
  return Array.from({ length: 8 }, (_, index) => ({
    id: `paged-turn-${index}`,
    items: [
      {
        type: "userMessage",
        id: `paged-user-${index}`,
        content: [{ type: "text", text: `paged user ${index}`, text_elements: [] }]
      },
      {
        type: "agentMessage",
        id: `paged-assistant-${index}`,
        text: `paged assistant ${index}`,
        phase: null,
        memoryCitation: null
      }
    ],
    status: "completed",
    error: null,
    startedAt: index + 1,
    completedAt: index + 2,
    durationMs: 1000
  }));
}

const rl = createInterface({ input: process.stdin });
const injectedUserTexts = [];
const mobileUserTexts = [];

function injectedHistoryTurns() {
  return injectedUserTexts.map((text, index) => ({
    id: `injected-turn-${index}`,
    items: [
      {
        type: "userMessage",
        id: `injected-user-${index}`,
        content: [{ type: "text", text, text_elements: [] }]
      }
    ],
    status: "completed",
    error: null,
    startedAt: 100 + index,
    completedAt: 101 + index,
    durationMs: 0
  }));
}

function storedTurns() {
  const base =
    process.env.MOCK_CODEX_PAGED_THREAD === "1"
      ? pagedHistoryTurns()
      : process.env.MOCK_CODEX_HUGE_THREAD === "1"
        ? hugeHistoryTurns()
        : [historyTurn()];
  if (process.env.MOCK_CODEX_DROP_MOBILE_USER === "1") {
    return [...base, ...injectedHistoryTurns()];
  }
  return [
    ...base,
    ...mobileUserTexts.map((text, index) => ({
      id: `mobile-turn-${index}`,
      items: [
        {
          type: "userMessage",
          id: `mobile-user-${index}`,
          content: [{ type: "text", text, text_elements: [] }]
        }
      ],
      status: "completed",
      error: null,
      startedAt: 200 + index,
      completedAt: 201 + index,
      durationMs: 0
    }))
  ];
}

rl.on("line", (line) => {
  if (!line.trim()) {
    return;
  }

  const message = JSON.parse(line);
  report({ direction: "fromBridge", message });

  if (message.method === "initialize") {
    send({
      id: message.id,
      result: {
        userAgent: "mock-codex-app-server",
        codexHome: process.cwd(),
        platformFamily: "unix",
        platformOs: "macos"
      }
    });
    return;
  }

  if (message.method === "initialized") {
    return;
  }

  if (message.method === "thread/start") {
    send({
      id: message.id,
      result: {
        thread: thread(),
        model: "gpt-5",
        modelProvider: "openai",
        serviceTier: null,
        cwd: message.params.cwd ?? process.cwd(),
        instructionSources: [],
        approvalPolicy: message.params.approvalPolicy,
        approvalsReviewer: message.params.approvalsReviewer,
        sandbox: { type: message.params.sandbox === "read-only" ? "readOnly" : "workspaceWrite" },
        permissionProfile: null,
        reasoningEffort: null
      }
    });
    send({ method: "thread/started", params: { thread: thread({ cwd: message.params.cwd ?? process.cwd() }) } });
    return;
  }

  if (message.method === "thread/list") {
    send({
      id: message.id,
      result: {
        data: [
          {
            ...thread(),
            id: "recent-thread-1",
            preview: "이전에 내가 한 질문",
            name: "Desktop chat",
            cwd: process.env.MOCK_CODEX_RECENT_CWD ?? process.cwd(),
            updatedAt: 3
          }
        ],
        nextCursor: null,
        backwardsCursor: null
      }
    });
    return;
  }

  if (message.method === "thread/resume") {
    const resumed = thread({
      id: message.params.threadId,
      preview: "이전에 내가 한 질문",
      name: "Desktop chat",
      cwd: process.env.MOCK_CODEX_RECENT_CWD ?? process.cwd(),
      turns: storedTurns()
    });
    send({
      id: message.id,
      result: {
        thread: resumed,
        model: message.params.model ?? "gpt-5",
        modelProvider: "openai",
        serviceTier: null,
        cwd: resumed.cwd,
        instructionSources: [],
        approvalPolicy: message.params.approvalPolicy,
        approvalsReviewer: message.params.approvalsReviewer,
        sandbox: { type: message.params.sandbox === "read-only" ? "readOnly" : "workspaceWrite" },
        permissionProfile: null,
        reasoningEffort: null
      }
    });
    send({ method: "thread/started", params: { thread: resumed } });
    return;
  }

  if (message.method === "thread/fork") {
    const forked = thread({
      id: "agent-thread-1",
      forkedFromId: message.params.threadId,
      preview: "",
      name: "Subagent",
      cwd: message.params.cwd ?? process.env.MOCK_CODEX_RECENT_CWD ?? process.cwd(),
      turns: []
    });
    send({
      id: message.id,
      result: {
        thread: forked,
        model: message.params.model ?? "gpt-5",
        modelProvider: "openai",
        serviceTier: null,
        cwd: forked.cwd,
        instructionSources: [],
        approvalPolicy: message.params.approvalPolicy,
        approvalsReviewer: message.params.approvalsReviewer,
        sandbox: { type: message.params.sandbox === "read-only" ? "readOnly" : "workspaceWrite" },
        permissionProfile: null,
        reasoningEffort: null
      }
    });
    send({ method: "thread/started", params: { thread: forked } });
    return;
  }

  if (message.method === "thread/compact/start") {
    send({ id: message.id, result: {} });
    send({
      method: "thread/compacted",
      params: {
        threadId: message.params.threadId
      }
    });
    return;
  }

  if (message.method === "thread/read") {
    send({
      id: message.id,
      result: {
        thread: thread({
          id: message.params.threadId,
          preview: "이전에 내가 한 질문",
          name: "Desktop chat",
          cwd: process.env.MOCK_CODEX_RECENT_CWD ?? process.cwd(),
          turns: message.params.includeTurns ? storedTurns() : []
        })
      }
    });
    return;
  }

  if (message.method === "thread/turns/list") {
    const turns = storedTurns();
    const limit = typeof message.params.limit === "number" ? message.params.limit : turns.length;
    const offset =
      typeof message.params.cursor === "string" && message.params.cursor.startsWith("offset:")
        ? Number(message.params.cursor.slice("offset:".length))
        : 0;
    const descending = message.params.sortDirection !== "asc";
    const orderedTurns = descending ? [...turns].reverse() : turns;
    const page = orderedTurns.slice(offset, offset + limit);
    const nextOffset = offset + page.length;
    send({
      id: message.id,
      result: {
        data: page,
        nextCursor: nextOffset < orderedTurns.length ? `offset:${nextOffset}` : null,
        backwardsCursor: page.length > 0 ? `offset:${Math.max(0, offset - limit)}` : null
      }
    });
    return;
  }

  if (message.method === "thread/inject_items") {
    for (const item of message.params.items ?? []) {
      if (item?.type !== "message" || item.role !== "user" || !Array.isArray(item.content)) {
        continue;
      }
      const text = item.content
        .filter((content) => content?.type === "input_text" && typeof content.text === "string")
        .map((content) => content.text)
        .join("\n")
        .trim();
      if (text) {
        injectedUserTexts.push(text);
      }
    }
    send({ id: message.id, result: {} });
    return;
  }

  if (message.method === "model/list") {
    send({
      id: message.id,
      result: {
        data: [
          {
            id: "gpt-5.5",
            model: "gpt-5.5",
            upgrade: null,
            upgradeInfo: null,
            availabilityNux: null,
            displayName: "GPT-5.5",
            description: "Frontier model",
            hidden: false,
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
            defaultReasoningEffort: "medium",
            inputModalities: ["text", "image"],
            supportsPersonality: true,
            additionalSpeedTiers: [],
            isDefault: true
          },
          {
            id: "gpt-5.4-mini",
            model: "gpt-5.4-mini",
            upgrade: null,
            upgradeInfo: null,
            availabilityNux: null,
            displayName: "GPT-5.4 Mini",
            description: "Fast everyday model",
            hidden: false,
            supportedReasoningEfforts: ["low", "medium", "high"],
            defaultReasoningEffort: "medium",
            inputModalities: ["text"],
            supportsPersonality: true,
            additionalSpeedTiers: [],
            isDefault: false
          }
        ],
        nextCursor: null
      }
    });
    return;
  }

  if (message.method === "turn/start") {
    const text = (message.params.input ?? [])
      .filter((input) => input?.type === "text" && typeof input.text === "string")
      .map((input) => input.text)
      .join("\n")
      .trim();
    if (text && process.env.MOCK_CODEX_DROP_MOBILE_USER !== "1") {
      mobileUserTexts.push(text);
    }
    send({ id: message.id, result: { turn: turn() } });
    send({ method: "turn/started", params: { threadId: message.params.threadId, turn: turn() } });
    if (process.env.MOCK_CODEX_AUTO_COMPLETE_TURN === "1") {
      send({
        method: "turn/completed",
        params: { threadId: message.params.threadId, turn: { ...turn("completed"), completedAt: 2, durationMs: 1000 } }
      });
      return;
    }
    send({
      method: "item/agentMessage/delta",
      params: { threadId: message.params.threadId, turnId: "turn-1", itemId: "item-1", delta: "hello" }
    });
    const approvalDelayMs = Number(process.env.MOCK_CODEX_DELAY_APPROVAL_MS ?? "0");
    if (Number.isFinite(approvalDelayMs) && approvalDelayMs > 0) {
      setTimeout(() => sendApprovalRequest(message), approvalDelayMs);
    } else {
      sendApprovalRequest(message);
    }
    return;
  }

  if (message.id === "approval-1" && "result" in message) {
    send({
      method: "serverRequest/resolved",
      params: { requestId: "approval-1" }
    });
    return;
  }

  if (message.method === "turn/interrupt") {
    send({ id: message.id, result: {} });
    send({
      method: "turn/completed",
      params: { threadId: "thread-1", turn: { ...turn("cancelled"), completedAt: 2, durationMs: 1000 } }
    });
    return;
  }

  if (message.method === "turn/steer") {
    send({ id: message.id, result: {} });
    return;
  }

  send({
    id: message.id,
    error: {
      code: -32601,
      message: `Unexpected mock method: ${message.method}`
    }
  });
});
