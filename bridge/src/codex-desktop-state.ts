import { randomBytes } from "node:crypto";
import { chmod, mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

export type CodexDesktopWorkspaceSyncResult = {
  changed: boolean;
  globalStateFile: string;
  root: string;
  updatedKeys: string[];
};

export type CodexDesktopThreadIndexSyncResult = {
  changed: boolean;
  sessionIndexFile: string;
  id: string;
};

type JsonRecord = Record<string, unknown>;

const GLOBAL_STATE_FILE = ".codex-global-state.json";
const SESSION_INDEX_FILE = "session_index.jsonl";
const ACTIVE_WORKSPACE_ROOTS_KEY = "active-workspace-roots";
const WORKSPACE_ROOT_OPTION_KEYS = ["electron-saved-workspace-roots", "project-order"] as const;

export async function registerCodexDesktopWorkspaceRoot(
  root: string,
  options: { codexHome?: string; label?: string; makeActive?: boolean; promote?: boolean } = {}
): Promise<CodexDesktopWorkspaceSyncResult> {
  const normalizedRoot = normalizeAbsoluteDirectory(root);
  const rootInfo = await stat(normalizedRoot);
  if (!rootInfo.isDirectory()) {
    throw new Error(`Codex desktop workspace root is not a directory: ${normalizedRoot}`);
  }

  const codexHome = normalizeCodexHome(options.codexHome);
  const globalStateFile = path.join(codexHome, GLOBAL_STATE_FILE);
  const { state, mode } = await readGlobalState(globalStateFile);
  const updatedKeys: string[] = [];

  for (const key of WORKSPACE_ROOT_OPTION_KEYS) {
    if (upsertUniqueString(state, key, normalizedRoot, options.promote === true ? "front" : "back")) {
      updatedKeys.push(key);
    }
  }

  if (options.makeActive === true && setSingleActiveWorkspaceRoot(state, normalizedRoot)) {
    updatedKeys.push(ACTIVE_WORKSPACE_ROOTS_KEY);
  }

  const labels = objectValue(state["electron-workspace-root-labels"]);
  if (state["electron-workspace-root-labels"] !== labels) {
    state["electron-workspace-root-labels"] = labels;
  }
  if (typeof labels[normalizedRoot] !== "string" || labels[normalizedRoot] === "") {
    labels[normalizedRoot] = options.label?.trim() || path.basename(normalizedRoot) || normalizedRoot;
    updatedKeys.push("electron-workspace-root-labels");
  }

  if (updatedKeys.length === 0) {
    return {
      changed: false,
      globalStateFile,
      root: normalizedRoot,
      updatedKeys
    };
  }

  await mkdir(codexHome, { recursive: true, mode: 0o700 });
  const tempFile = path.join(
    codexHome,
    `.${GLOBAL_STATE_FILE}.${process.pid}.${Date.now()}.${randomBytes(4).toString("hex")}.tmp`
  );
  await writeFile(tempFile, `${JSON.stringify(state, null, 2)}\n`, { mode });
  await chmod(tempFile, mode);
  await rename(tempFile, globalStateFile);

  return {
    changed: true,
    globalStateFile,
    root: normalizedRoot,
    updatedKeys
  };
}

export async function registerCodexDesktopThreadIndex(
  entry: { id: string; threadName?: string; updatedAt?: string | number | Date },
  options: { codexHome?: string; fallbackName?: string } = {}
): Promise<CodexDesktopThreadIndexSyncResult> {
  const id = normalizeThreadId(entry.id);
  const codexHome = normalizeCodexHome(options.codexHome);
  const sessionIndexFile = path.join(codexHome, SESSION_INDEX_FILE);
  const { entries, mode } = await readSessionIndex(sessionIndexFile);
  const next = {
    id,
    thread_name: normalizeThreadName(entry.threadName ?? options.fallbackName ?? id),
    updated_at: normalizeUpdatedAt(entry.updatedAt)
  };

  const index = entries.findIndex((item) => item.id === id);
  if (index >= 0) {
    const current = entries[index];
    if (current.thread_name === next.thread_name && current.updated_at === next.updated_at) {
      return { changed: false, sessionIndexFile, id };
    }
    entries[index] = next;
  } else {
    entries.push(next);
  }

  await mkdir(codexHome, { recursive: true, mode: 0o700 });
  const tempFile = path.join(
    codexHome,
    `.${SESSION_INDEX_FILE}.${process.pid}.${Date.now()}.${randomBytes(4).toString("hex")}.tmp`
  );
  await writeFile(tempFile, `${entries.map((item) => JSON.stringify(item)).join("\n")}\n`, { mode });
  await chmod(tempFile, mode);
  await rename(tempFile, sessionIndexFile);

  return { changed: true, sessionIndexFile, id };
}

function normalizeAbsoluteDirectory(root: string): string {
  if (typeof root !== "string" || root.trim() === "") {
    throw new Error("Codex desktop workspace root must be a non-empty absolute path.");
  }
  const expanded = root.startsWith("~/") ? path.join(homedir(), root.slice(2)) : root;
  if (!path.isAbsolute(expanded)) {
    throw new Error(`Codex desktop workspace root must be absolute: ${root}`);
  }
  return path.resolve(expanded);
}

function normalizeCodexHome(codexHome: string | undefined): string {
  const value = codexHome && codexHome.trim() ? codexHome : path.join(homedir(), ".codex");
  const expanded = value.startsWith("~/") ? path.join(homedir(), value.slice(2)) : value;
  return path.resolve(expanded);
}

function normalizeThreadId(id: string): string {
  if (typeof id !== "string" || id.trim() === "") {
    throw new Error("Codex desktop thread index id must be a non-empty string.");
  }
  return id.trim();
}

function normalizeThreadName(name: string): string {
  const normalized = name.replace(/\s+/g, " ").trim();
  return normalized ? normalized.slice(0, 120) : "maludex mobile thread";
}

function normalizeUpdatedAt(updatedAt: string | number | Date | undefined): string {
  if (updatedAt instanceof Date) {
    return updatedAt.toISOString();
  }
  if (typeof updatedAt === "number" && Number.isFinite(updatedAt)) {
    return new Date(updatedAt).toISOString();
  }
  if (typeof updatedAt === "string" && updatedAt.trim()) {
    const parsed = new Date(updatedAt);
    if (!Number.isNaN(parsed.valueOf())) {
      return parsed.toISOString();
    }
  }
  return new Date().toISOString();
}

async function readGlobalState(file: string): Promise<{ state: JsonRecord; mode: number }> {
  try {
    const info = await stat(file);
    const content = await readFile(file, "utf8");
    if (!content.trim()) {
      return { state: {}, mode: info.mode & 0o777 };
    }
    const parsed = JSON.parse(content) as unknown;
    if (!isRecord(parsed)) {
      throw new Error(`Codex desktop global state must contain a JSON object: ${file}`);
    }
    return { state: parsed, mode: info.mode & 0o777 };
  } catch (error) {
    if (isNodeError(error) && error.code === "ENOENT") {
      return { state: {}, mode: 0o600 };
    }
    throw error;
  }
}

async function readSessionIndex(file: string): Promise<{ entries: Array<{ id: string; thread_name: string; updated_at: string }>; mode: number }> {
  try {
    const info = await stat(file);
    const content = await readFile(file, "utf8");
    const entries = content
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line) as unknown)
      .filter((item): item is { id: string; thread_name: string; updated_at: string } => {
        return (
          isRecord(item) &&
          typeof item.id === "string" &&
          typeof item.thread_name === "string" &&
          typeof item.updated_at === "string"
        );
      });
    return { entries, mode: info.mode & 0o777 };
  } catch (error) {
    if (isNodeError(error) && error.code === "ENOENT") {
      return { entries: [], mode: 0o644 };
    }
    throw error;
  }
}

function upsertUniqueString(state: JsonRecord, key: string, value: string, position: "front" | "back"): boolean {
  const current = Array.isArray(state[key]) ? (state[key] as unknown[]) : [];
  const strings = current.filter((item): item is string => typeof item === "string");
  const normalizedCurrentChanged =
    current.length !== strings.length || current.some((item, index) => item !== strings[index]);
  if (position === "back" && strings.includes(value)) {
    if (normalizedCurrentChanged) {
      state[key] = strings;
      return true;
    }
    return false;
  }
  const withoutValue = strings.filter((item) => item !== value);
  const next = position === "front" ? [value, ...withoutValue] : [...withoutValue, value];
  if (strings.length === next.length && strings.every((item, index) => item === next[index])) {
    if (normalizedCurrentChanged) {
      state[key] = strings;
      return true;
    }
    return false;
  }
  state[key] = next;
  return true;
}

function setSingleActiveWorkspaceRoot(state: JsonRecord, value: string): boolean {
  const current = Array.isArray(state[ACTIVE_WORKSPACE_ROOTS_KEY])
    ? (state[ACTIVE_WORKSPACE_ROOTS_KEY] as unknown[]).filter((item): item is string => typeof item === "string")
    : [];
  if (current.length === 1 && current[0] === value) {
    return false;
  }
  state[ACTIVE_WORKSPACE_ROOTS_KEY] = [value];
  return true;
}

function objectValue(value: unknown): JsonRecord {
  return isRecord(value) ? value : {};
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error;
}
