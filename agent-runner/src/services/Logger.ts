/**
 * Structured JSON logger — one JSON object per line.
 * Replaces console.log/error/warn with structured output for grep-ability
 * and log aggregation.
 */

export interface Logger {
  readonly info: (fields: Record<string, unknown>) => void;
  readonly warn: (fields: Record<string, unknown>) => void;
  readonly error: (fields: Record<string, unknown>) => void;
}

function emit(stream: NodeJS.WriteStream, level: string, fields: Record<string, unknown>): void {
  const entry = { level, timestamp: new Date().toISOString(), ...fields };
  stream.write(JSON.stringify(entry) + "\n");
}

export function createLogger(): Logger {
  return {
    info: (fields) => emit(process.stdout, "info", fields),
    warn: (fields) => emit(process.stdout, "warn", fields),
    error: (fields) => emit(process.stderr, "error", fields),
  };
}

/** Singleton logger instance for the agent-runner process. */
export const log = createLogger();
