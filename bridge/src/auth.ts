import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import type { IncomingMessage } from "node:http";
import path from "node:path";

const MIN_TOKEN_BYTES = 32;
const REQUIRED_TOKEN_MODE = 0o600;

export function generateCapabilityToken(): string {
  return randomBytes(MIN_TOKEN_BYTES).toString("base64url");
}

export function loadCapabilityTokenFromFile(path: string): string {
  const stat = statSync(path);
  if (!stat.isFile()) {
    throw new Error(`Capability token file must be a regular file: ${path}`);
  }

  const mode = stat.mode & 0o777;
  if (mode !== REQUIRED_TOKEN_MODE) {
    throw new Error(`Capability token file must have 0600 permissions. Found ${mode.toString(8)} at ${path}.`);
  }

  const token = readFileSync(path, "utf8").trim();
  if (Buffer.byteLength(token, "utf8") < MIN_TOKEN_BYTES) {
    throw new Error("Capability token file does not contain at least 32 bytes of token material.");
  }
  return token;
}

export async function rotateCapabilityTokenFile(tokenFile: string): Promise<string> {
  const token = generateCapabilityToken();
  const directory = path.dirname(tokenFile);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const tempFile = path.join(directory, `.token-${process.pid}-${Date.now()}.tmp`);
  await writeFile(tempFile, `${token}\n`, { mode: REQUIRED_TOKEN_MODE, flag: "wx" });
  await chmod(tempFile, REQUIRED_TOKEN_MODE);
  await rename(tempFile, tokenFile);
  await chmod(tokenFile, REQUIRED_TOKEN_MODE);
  return token;
}

export class CapabilityAuthenticator {
  private readonly tokenDigest: Buffer;

  constructor(token: string) {
    if (Buffer.byteLength(token, "utf8") < MIN_TOKEN_BYTES) {
      throw new Error("Capability token must contain at least 32 bytes of entropy.");
    }
    this.tokenDigest = digest(token);
  }

  isAuthorized(request: IncomingMessage): boolean {
    const token = bearerToken(request.headers.authorization);
    if (!token) {
      return false;
    }

    const presented = digest(token);
    return presented.length === this.tokenDigest.length && timingSafeEqual(presented, this.tokenDigest);
  }

  hasSameToken(token: string): boolean {
    const presented = digest(token);
    return presented.length === this.tokenDigest.length && timingSafeEqual(presented, this.tokenDigest);
  }
}

function bearerToken(value: string | undefined): string | null {
  if (!value) {
    return null;
  }
  const match = /^Bearer\s+(.+)$/i.exec(value.trim());
  return match?.[1] ?? null;
}

function digest(token: string): Buffer {
  return createHash("sha256").update(token, "utf8").digest();
}
