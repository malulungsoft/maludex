export function childProcessFailureMessage(error: unknown): string {
  const base = error instanceof Error ? error.message : String(error);
  const output = [streamText(record(error).stderr), streamText(record(error).stdout)]
    .map((value) => value.trim())
    .filter(Boolean)
    .join("\n");

  return output ? `${base}\n${output}` : base;
}

function streamText(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  if (Buffer.isBuffer(value)) {
    return value.toString("utf8");
  }
  return "";
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
