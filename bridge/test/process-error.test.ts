import { describe, expect, test } from "vitest";

import { childProcessFailureMessage } from "../src/process-error.js";

describe("childProcessFailureMessage", () => {
  test("includes stderr from failed child processes", () => {
    const error = Object.assign(new Error("Command failed: scripts/install-launch-agent.sh"), {
      stderr: Buffer.from("npm was not found. Install Node.js 20 or newer first.\n"),
      stdout: Buffer.from("")
    });

    expect(childProcessFailureMessage(error)).toContain("Command failed: scripts/install-launch-agent.sh");
    expect(childProcessFailureMessage(error)).toContain("npm was not found");
  });

  test("includes stdout when stderr is empty", () => {
    const error = Object.assign(new Error("Command failed: scripts/install-launch-agent.sh"), {
      stdout: Buffer.from("Codex CLI is required.\n")
    });

    expect(childProcessFailureMessage(error)).toContain("Codex CLI is required.");
  });
});
