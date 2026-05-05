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

type JsonRecord = Record<string, unknown>;

const GLOBAL_STATE_FILE = ".codex-global-state.json";
const WORKSPACE_ROOT_KEYS = ["active-workspace-roots", "electron-saved-workspace-roots", "project-order"] as const;

export async function registerCodexDesktopWorkspaceRoot(
  root: string,
  options: { codexHome?: string; label?: string } = {}
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

  for (const key of WORKSPACE_ROOT_KEYS) {
    if (appendUniqueString(state, key, normalizedRoot)) {
      updatedKeys.push(key);
    }
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

function appendUniqueString(state: JsonRecord, key: string, value: string): boolean {
  const current = Array.isArray(state[key]) ? (state[key] as unknown[]) : [];
  const strings = current.filter((item): item is string => typeof item === "string");
  const normalizedCurrentChanged =
    current.length !== strings.length || current.some((item, index) => item !== strings[index]);
  if (strings.includes(value)) {
    if (normalizedCurrentChanged) {
      state[key] = strings;
      return true;
    }
    return false;
  }
  state[key] = [...strings, value];
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
