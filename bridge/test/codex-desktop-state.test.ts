import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "vitest";

import { registerCodexDesktopThreadIndex, registerCodexDesktopWorkspaceRoot } from "../src/codex-desktop-state.js";

test("registers a workspace root in Codex Desktop global state without dropping existing keys", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "maludex-codex-state-"));
  const codexHome = path.join(temp, "codex-home");
  const workspace = path.join(temp, "webnovel");
  const existing = path.join(temp, "existing");
  await mkdir(workspace, { recursive: true });
  await mkdir(existing, { recursive: true });
  await mkdir(codexHome, { recursive: true });

  const globalStateFile = path.join(codexHome, ".codex-global-state.json");
  await writeFile(
    globalStateFile,
    `${JSON.stringify({
      "active-workspace-roots": [existing],
      "electron-saved-workspace-roots": [existing],
      "electron-workspace-root-labels": {
        [existing]: "Existing"
      },
      "project-order": [existing],
      "prompt-history": ["keep me"]
    })}\n`,
    { mode: 0o644 }
  );
  await chmod(globalStateFile, 0o644);

  const result = await registerCodexDesktopWorkspaceRoot(workspace, {
    codexHome,
    label: "webnovel"
  });
  expect(result.changed).toBe(true);

  const state = JSON.parse(await readFile(globalStateFile, "utf8")) as Record<string, unknown>;
  expect(state["active-workspace-roots"]).toEqual([existing, workspace]);
  expect(state["electron-saved-workspace-roots"]).toEqual([existing, workspace]);
  expect(state["project-order"]).toEqual([existing, workspace]);
  expect(state["electron-workspace-root-labels"]).toMatchObject({
    [existing]: "Existing",
    [workspace]: "webnovel"
  });
  expect(state["prompt-history"]).toEqual(["keep me"]);
  expect((await stat(globalStateFile)).mode & 0o777).toBe(0o644);

  const second = await registerCodexDesktopWorkspaceRoot(workspace, { codexHome, label: "ignored" });
  expect(second.changed).toBe(false);

  await rm(temp, { recursive: true, force: true });
});

test("registers a thread in Codex Desktop session index without prompt bodies", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "maludex-codex-index-"));
  const codexHome = path.join(temp, "codex-home");
  const sessionIndexFile = path.join(codexHome, "session_index.jsonl");
  await mkdir(codexHome, { recursive: true });
  await writeFile(
    sessionIndexFile,
    `${JSON.stringify({
      id: "existing-thread",
      thread_name: "Existing",
      updated_at: "2026-05-01T00:00:00.000Z"
    })}\n`,
    { mode: 0o644 }
  );
  await chmod(sessionIndexFile, 0o644);

  const result = await registerCodexDesktopThreadIndex(
    {
      id: "mobile-thread",
      threadName: "webnovel",
      updatedAt: "2026-05-05T04:17:17.322Z"
    },
    { codexHome }
  );
  expect(result.changed).toBe(true);

  const rows = (await readFile(sessionIndexFile, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as Record<string, unknown>);
  expect(rows).toEqual([
    {
      id: "existing-thread",
      thread_name: "Existing",
      updated_at: "2026-05-01T00:00:00.000Z"
    },
    {
      id: "mobile-thread",
      thread_name: "webnovel",
      updated_at: "2026-05-05T04:17:17.322Z"
    }
  ]);
  expect((await stat(sessionIndexFile)).mode & 0o777).toBe(0o644);

  const second = await registerCodexDesktopThreadIndex(
    {
      id: "mobile-thread",
      threadName: "webnovel",
      updatedAt: "2026-05-05T04:17:17.322Z"
    },
    { codexHome }
  );
  expect(second.changed).toBe(false);

  await rm(temp, { recursive: true, force: true });
});
