import { describe, expect, test } from "vitest";

import { extractReleaseNotes } from "../../scripts/extract-release-notes.mjs";

describe("extractReleaseNotes", () => {
  test("returns only the requested changelog section", () => {
    const markdown = [
      "# Changelog",
      "",
      "## 0.4.0 - 2026-05-04",
      "",
      "- Release automation",
      "- Diagnostics",
      "",
      "## 0.3.0",
      "",
      "- Older notes"
    ].join("\n");

    expect(extractReleaseNotes(markdown, "0.4.0")).toBe("- Release automation\n- Diagnostics");
  });

  test("fails when the version entry is missing", () => {
    expect(() => extractReleaseNotes("## 0.3.0\n\n- notes", "0.4.0")).toThrow(/0\.4\.0/);
  });
});
