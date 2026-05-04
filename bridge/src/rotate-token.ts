#!/usr/bin/env node
import QRCode from "qrcode";
import qrcode from "qrcode-terminal";
import { chmodSync } from "node:fs";
import { homedir, hostname } from "node:os";
import path from "node:path";
import { rotateCapabilityTokenFile } from "./auth.js";
import { pairingUriFor } from "./pairing-uri.js";

type RotateOptions = {
  host: string;
  port: number;
  tokenFile: string;
  name: string;
  tls: boolean;
  qrFile?: string;
};

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const token = await rotateCapabilityTokenFile(options.tokenFile);
  const pairingUri = pairingUriFor({
    host: options.host,
    port: options.port,
    token,
    name: options.name,
    tls: options.tls
  });

  process.stdout.write("maludex pairing token rotated.\n");
  process.stdout.write(`Token file: ${options.tokenFile}\n`);
  process.stdout.write("Existing iPhone connections will be disconnected; pair again with the new QR.\n");
  process.stdout.write("The raw token is intentionally not printed.\n\n");

  if (options.qrFile) {
    await QRCode.toFile(options.qrFile, pairingUri, {
      type: "png",
      margin: 2,
      scale: 8
    });
    chmodSync(options.qrFile, 0o600);
    process.stdout.write(`Pairing QR: ${options.qrFile}\n`);
  } else {
    qrcode.generate(pairingUri, { small: true });
    process.stdout.write("\n");
  }
}

function parseArgs(args: string[]): RotateOptions {
  const options: RotateOptions = {
    host: process.env.BRIDGE_HOST ?? "127.0.0.1",
    port: Number(process.env.BRIDGE_PORT ?? 8765),
    tokenFile: process.env.BRIDGE_TOKEN_FILE ?? defaultTokenFile(),
    name: process.env.BRIDGE_NAME ?? hostname(),
    tls: process.env.BRIDGE_TLS === "1"
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--host") {
      options.host = requiredValue(args, ++index, "--host");
    } else if (arg === "--port") {
      options.port = Number(requiredValue(args, ++index, "--port"));
    } else if (arg === "--token-file") {
      options.tokenFile = requiredValue(args, ++index, "--token-file");
    } else if (arg === "--name") {
      options.name = requiredValue(args, ++index, "--name");
    } else if (arg === "--tls") {
      options.tls = true;
    } else if (arg === "--qr-file") {
      options.qrFile = requiredValue(args, ++index, "--qr-file");
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

function printHelp(): void {
  process.stdout.write(`maludex rotate-token

Usage:
  npm run rotate-token -- [--host 127.0.0.1] [--port 8765]

Options:
  --host <host>      Host to encode in the new pairing QR.
  --port <port>      WebSocket port to encode in the new pairing QR.
  --token-file <p>   0600 file to replace with a new bearer capability token.
  --name <name>      Friendly bridge name shown on the iPhone.
  --tls              Encode wss pairing for an Nginx/TLS endpoint.
  --qr-file <path>   Write a 0600 PNG QR instead of rendering in the terminal.
`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`token rotation failed: ${message}\n`);
  process.exit(1);
});
