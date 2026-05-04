#!/usr/bin/env node
import qrcode from "qrcode-terminal";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir, hostname } from "node:os";
import path from "node:path";
import { generateCapabilityToken, loadCapabilityTokenFromFile } from "./auth.js";
import { BridgeServer } from "./bridge-server.js";
import { createLogger } from "./logger.js";
import { pairingUriFor } from "./pairing-uri.js";

type CliOptions = {
  host: string;
  port: number;
  codexCommand: string;
  codexArgs: string[];
  tokenFile: string;
  mobileHandoffMaxEntries?: number;
  qr: boolean;
  name: string;
  tls: boolean;
};

async function main() {
  const options = parseArgs(process.argv.slice(2));
  ensureTokenFile(options.tokenFile);
  const token = loadCapabilityTokenFromFile(options.tokenFile);
  const logger = createLogger();
  const server = new BridgeServer({
    host: options.host,
    port: options.port,
    tokenFile: options.tokenFile,
    mobileHandoffMaxEntries: options.mobileHandoffMaxEntries,
    codexCommand: options.codexCommand,
    codexArgs: options.codexArgs,
    logger
  });

  await server.start();
  const address = server.address();
  const pairingUri = pairingUriFor({
    host: address.host,
    port: address.port,
    token,
    name: options.name,
    tls: options.tls
  });

  process.stdout.write("\nmaludex bridge is listening.\n");
  process.stdout.write(`WebSocket: ws://${address.host}:${address.port}\n`);
  process.stdout.write("Auth: scan the QR code with the iPhone app. The raw token is intentionally not printed.\n\n");
  if (options.qr) {
    qrcode.generate(pairingUri, { small: true });
    process.stdout.write("\n");
  }
  if (address.host === "127.0.0.1" || address.host === "::1" || address.host === "localhost") {
    process.stdout.write("Physical iPhones cannot reach Mac localhost; use --host <tailscale-ip> for device testing.\n");
  }

  const shutdown = async () => {
    process.stdout.write("\nStopping bridge...\n");
    await server.stop();
    process.exit(0);
  };
  process.once("SIGINT", () => {
    void shutdown();
  });
  process.once("SIGTERM", () => {
    void shutdown();
  });
}

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    host: process.env.BRIDGE_HOST ?? "127.0.0.1",
    port: Number(process.env.BRIDGE_PORT ?? 8765),
    codexCommand: process.env.CODEX_BIN ?? "codex",
    codexArgs: ["app-server", "--listen", "stdio://"],
    tokenFile: process.env.BRIDGE_TOKEN_FILE ?? defaultTokenFile(),
    mobileHandoffMaxEntries: parseOptionalBoundedInteger(
      process.env.BRIDGE_MOBILE_HANDOFF_MAX_ENTRIES,
      "BRIDGE_MOBILE_HANDOFF_MAX_ENTRIES"
    ),
    qr: true,
    name: process.env.BRIDGE_NAME ?? hostname(),
    tls: process.env.BRIDGE_TLS === "1"
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--host") {
      options.host = requiredValue(args, ++index, "--host");
    } else if (arg === "--port") {
      options.port = Number(requiredValue(args, ++index, "--port"));
    } else if (arg === "--codex-bin") {
      options.codexCommand = requiredValue(args, ++index, "--codex-bin");
    } else if (arg === "--codex-arg") {
      options.codexArgs.push(requiredValue(args, ++index, "--codex-arg"));
    } else if (arg === "--token-file") {
      options.tokenFile = requiredValue(args, ++index, "--token-file");
    } else if (arg === "--mobile-handoff-max-entries") {
      options.mobileHandoffMaxEntries = parseBoundedInteger(
        requiredValue(args, ++index, "--mobile-handoff-max-entries"),
        "--mobile-handoff-max-entries"
      );
    } else if (arg === "--name") {
      options.name = requiredValue(args, ++index, "--name");
    } else if (arg === "--tls") {
      options.tls = true;
    } else if (arg === "--no-qr") {
      options.qr = false;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!Number.isInteger(options.port) || options.port <= 0 || options.port > 65535) {
    throw new Error("--port must be an integer between 1 and 65535.");
  }
  return options;
}

function ensureTokenFile(tokenFile: string): void {
  if (existsSync(tokenFile)) {
    return;
  }

  mkdirSync(path.dirname(tokenFile), { recursive: true, mode: 0o700 });
  writeFileSync(tokenFile, `${generateCapabilityToken()}\n`, { mode: 0o600, flag: "wx" });
  chmodSync(tokenFile, 0o600);
}

function defaultTokenFile(): string {
  return path.join(homedir(), ".codex-iphone-remote-bridge", "token");
}

function requiredValue(args: string[], index: number, flag: string): string {
  const value = args[index];
  if (!value) {
    throw new Error(`${flag} requires a value.`);
  }
  return value;
}

function parseOptionalBoundedInteger(value: string | undefined, name: string): number | undefined {
  if (value === undefined || value.trim() === "") {
    return undefined;
  }
  return parseBoundedInteger(value, name);
}

function parseBoundedInteger(value: string, name: string): number {
  if (!/^\d+$/.test(value)) {
    throw new Error(`${name} must be an integer between 1 and 1000.`);
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || !Number.isInteger(parsed) || parsed < 1 || parsed > 1_000) {
    throw new Error(`${name} must be an integer between 1 and 1000.`);
  }
  return parsed;
}

function printHelp(): void {
  process.stdout.write(`maludex bridge

Usage:
  npm run dev -- [--host 127.0.0.1] [--port 8765]

Options:
  --host <ip>         Bind to localhost or a specific Tailscale IP. Wildcard binds are refused.
  --port <port>      WebSocket port. Defaults to 8765.
  --token-file <p>   0600 file containing the bearer capability token.
  --mobile-handoff-max-entries <n>
                      Keep this many iPhone-authored handoff prompts. Defaults to 200.
  --name <name>      Friendly bridge name shown on the iPhone. Defaults to hostname.
  --tls              Encode wss pairing for an Nginx/TLS endpoint.
  --codex-bin <bin>  Codex executable. Defaults to codex.
  --codex-arg <arg>  Extra argument appended after: app-server --listen stdio://
  --no-qr            Do not render the QR pairing code.
`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`bridge failed: ${message}\n`);
  process.exit(1);
});
