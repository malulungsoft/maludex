#!/usr/bin/env node
import { homedir } from "node:os";
import path from "node:path";
import { readMobileHandoffEntries } from "./mobile-handoff-store.js";

type Options = {
  file: string;
  limit: number;
  json: boolean;
};

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const entries = await readMobileHandoffEntries(options.file, options.limit);

  if (options.json) {
    process.stdout.write(`${JSON.stringify({ file: options.file, entries }, null, 2)}\n`);
    return;
  }

  process.stdout.write(`maludex mobile handoff inbox\n`);
  process.stdout.write(`File: ${options.file}\n`);
  if (entries.length === 0) {
    process.stdout.write("No iPhone-authored requests are waiting in the handoff inbox.\n");
    return;
  }

  for (const entry of entries) {
    const title = [
      entry.createdAt,
      entry.kind,
      `thread=${shortId(entry.threadId)}`,
      entry.turnId ? `turn=${shortId(entry.turnId)}` : null,
      entry.cwd ? `cwd=${entry.cwd}` : null,
      entry.model ? `model=${entry.model}` : null,
      entry.role ? `role=${entry.role}` : null,
      entry.attachments.length > 0 ? `attachments=${entry.attachments.length}` : null
    ]
      .filter(Boolean)
      .join(" ");
    process.stdout.write(`\n[${title}]\n`);
    process.stdout.write(`${entry.prompt}\n`);
    if (entry.attachments.length > 0) {
      process.stdout.write("Attachments:\n");
      for (const attachment of entry.attachments) {
        const mime = attachment.mimeType ? `, ${attachment.mimeType}` : "";
        process.stdout.write(`- ${attachment.filename}: ${attachment.kind}${mime}, ${attachment.bytes} bytes\n`);
      }
    }
  }
}

function parseArgs(args: string[]): Options {
  const options: Options = {
    file: path.join(homedir(), ".codex-iphone-remote-bridge", "mobile-handoff.jsonl"),
    limit: 10,
    json: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--file") {
      options.file = requiredValue(args, ++index, "--file");
    } else if (arg === "--limit") {
      const limit = Number.parseInt(requiredValue(args, ++index, "--limit"), 10);
      if (!Number.isFinite(limit) || limit <= 0) {
        throw new Error("--limit must be a positive integer.");
      }
      options.limit = limit;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

function requiredValue(args: string[], index: number, flag: string): string {
  const value = args[index];
  if (!value) {
    throw new Error(`${flag} requires a value.`);
  }
  return value;
}

function shortId(id: string): string {
  return id.length <= 10 ? id : `${id.slice(0, 8)}...`;
}

function printHelp(): void {
  process.stdout.write(`maludex mobile handoff

Print recent iPhone-authored requests that were saved for desktop handoff.
The handoff file can contain prompt bodies, so treat the output as private.

Usage:
  npm run handoff -- [--limit 10] [--json]

Options:
  --file <path>   Handoff JSONL file. Defaults to ~/.codex-iphone-remote-bridge/mobile-handoff.jsonl.
  --limit <n>     Number of recent entries to print. Defaults to 10.
  --json          Print JSON for tools.
`);
}

main().catch((error) => {
  process.stderr.write(`handoff failed: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});
