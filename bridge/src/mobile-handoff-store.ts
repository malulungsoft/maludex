import { randomUUID } from "node:crypto";
import { appendFile, chmod, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import type { MobileAttachment, SubagentRole } from "./types.js";

export type MobileHandoffKind = "turn.start" | "turn.steer" | "subagent.start";

export type MobileHandoffAttachment = {
  kind: "image" | "file";
  filename: string;
  mimeType?: string;
  bytes: number;
};

export type MobileHandoffEntry = {
  schemaVersion: 1;
  id: string;
  createdAt: string;
  source: "iphone";
  kind: MobileHandoffKind;
  threadId: string;
  turnId?: string;
  cwd?: string;
  model?: string;
  role?: SubagentRole;
  prompt: string;
  promptBytes: number;
  attachments: MobileHandoffAttachment[];
};

export type NewMobileHandoffEntry = Omit<MobileHandoffEntry, "schemaVersion" | "id" | "createdAt" | "source">;

export const DEFAULT_MAX_HANDOFF_ENTRIES = 200;

export function boundedMobileHandoffMaxEntries(maxEntries = DEFAULT_MAX_HANDOFF_ENTRIES): number {
  const normalized = Number.isFinite(maxEntries) ? Math.trunc(maxEntries) : DEFAULT_MAX_HANDOFF_ENTRIES;
  return Math.max(1, Math.min(normalized, 1_000));
}

export class MobileHandoffStore {
  constructor(
    private readonly file: string,
    private readonly maxEntries = DEFAULT_MAX_HANDOFF_ENTRIES
  ) {}

  async record(entry: NewMobileHandoffEntry): Promise<MobileHandoffEntry> {
    await mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const persisted: MobileHandoffEntry = {
      schemaVersion: 1,
      id: `handoff-${randomUUID()}`,
      createdAt: new Date().toISOString(),
      source: "iphone",
      ...entry
    };
    await appendFile(this.file, `${JSON.stringify(persisted)}\n`, { mode: 0o600 });
    await chmod(this.file, 0o600);
    await this.prune();
    return persisted;
  }

  private async prune(): Promise<void> {
    const maxEntries = boundedMobileHandoffMaxEntries(this.maxEntries);
    const entries = await readAllMobileHandoffEntries(this.file);
    if (entries.length <= maxEntries) {
      return;
    }

    const retained = entries.slice(-maxEntries);
    await writeFile(this.file, `${retained.map((entry) => JSON.stringify(entry)).join("\n")}\n`, { mode: 0o600 });
    await chmod(this.file, 0o600);
  }
}

export async function readMobileHandoffEntries(file: string, limit = 20): Promise<MobileHandoffEntry[]> {
  const entries = await readAllMobileHandoffEntries(file);
  return entries.slice(-Math.max(1, Math.min(limit, 200))).reverse();
}

async function readAllMobileHandoffEntries(file: string): Promise<MobileHandoffEntry[]> {
  let stats;
  try {
    stats = await stat(file);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return [];
    }
    throw error;
  }
  if (!stats.isFile()) {
    throw new Error(`Mobile handoff path is not a file: ${file}`);
  }
  if ((stats.mode & 0o777) !== 0o600) {
    throw new Error(`Mobile handoff file must have 0600 permissions: ${file}`);
  }

  const content = await readFile(file, "utf8");
  return content
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as MobileHandoffEntry);
}

export function handoffAttachments(attachments: MobileAttachment[] | undefined): MobileHandoffAttachment[] {
  if (!Array.isArray(attachments)) {
    return [];
  }
  return attachments.map((attachment) => ({
    kind: attachment.kind,
    filename: attachment.filename,
    mimeType: attachment.mimeType,
    bytes: Buffer.byteLength(attachment.dataBase64, "base64")
  }));
}
