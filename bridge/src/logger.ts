export type LogLevel = "debug" | "info" | "warn" | "error";

export type LogEntry = {
  level: LogLevel;
  event: string;
  timestamp: string;
  fields?: Record<string, unknown>;
};

export type Logger = {
  debug(event: string, fields?: Record<string, unknown>): void;
  info(event: string, fields?: Record<string, unknown>): void;
  warn(event: string, fields?: Record<string, unknown>): void;
  error(event: string, fields?: Record<string, unknown>): void;
};

type LoggerOptions = {
  sink?: (entry: LogEntry) => void;
  minLevel?: LogLevel;
};

const levelWeight: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40
};

export function createLogger(options: LoggerOptions = {}): Logger {
  const minLevel = options.minLevel ?? "info";
  const sink =
    options.sink ??
    ((entry: LogEntry) => {
      process.stderr.write(`${JSON.stringify(entry)}\n`);
    });

  function emit(level: LogLevel, event: string, fields?: Record<string, unknown>) {
    if (levelWeight[level] < levelWeight[minLevel]) {
      return;
    }
    sink({
      level,
      event,
      timestamp: new Date().toISOString(),
      fields
    });
  }

  return {
    debug: (event, fields) => emit("debug", event, fields),
    info: (event, fields) => emit("info", event, fields),
    warn: (event, fields) => emit("warn", event, fields),
    error: (event, fields) => emit("error", event, fields)
  };
}
