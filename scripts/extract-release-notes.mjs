#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export function extractReleaseNotes(markdown, version) {
  const heading = new RegExp(`^## \\[?${escapeRegExp(version)}\\]?(?:\\s+-\\s+.+)?\\s*$`, "m");
  const match = markdown.match(heading);
  if (!match || match.index === undefined) {
    throw new Error(`CHANGELOG entry for ${version} was not found.`);
  }

  const start = match.index + match[0].length;
  const rest = markdown.slice(start);
  const nextHeading = rest.search(/^##\s+/m);
  const body = (nextHeading >= 0 ? rest.slice(0, nextHeading) : rest).trim();
  if (!body) {
    throw new Error(`CHANGELOG entry for ${version} is empty.`);
  }
  return body;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function main() {
  const [version, changelogPath = "CHANGELOG.md"] = process.argv.slice(2);
  if (!version) {
    throw new Error("Usage: extract-release-notes.mjs <version> [CHANGELOG.md]");
  }
  const markdown = await readFile(changelogPath, "utf8");
  process.stdout.write(`${extractReleaseNotes(markdown, version)}\n`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
