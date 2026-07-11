/**
 * Usage capture for the ledger: after a billed call completes, report its
 * token counts to Rails `record-usage`, which completes the pending
 * LLMUsageRecord that select-payer opened (keyed by selection_id).
 *
 * Reporting is advisory and must never affect the billed call: reportUsage
 * retries once and swallows every failure (Rails dedups on selection_id, so
 * a retry after a slow success is harmless). When a stream carries no usage
 * block, nothing is reported — the row staying "pending" is the honest
 * signal that usage never came back, where zeros would fake a free call.
 */

import { buildHeaders } from "../services/HmacSigner.js";
import type { RailsHttpService } from "../services/RailsHttp.js";
import { log } from "../services/Logger.js";

const RECORD_USAGE_PATH = "/internal/llm-gateway/record-usage";

export interface Usage {
  readonly inputTokens: number;
  readonly outputTokens: number;
}

// Bounds memory when accumulating a non-streamed JSON body for parsing; a
// body past this is abandoned (usage unreported), never truncated-and-parsed.
const MAX_JSON_ACCUMULATION_BYTES = 4 * 1024 * 1024;

const usageFromObject = (value: unknown): Usage | null => {
  if (typeof value !== "object" || value === null) return null;
  const usage = (value as Record<string, unknown>)["usage"];
  if (typeof usage !== "object" || usage === null) return null;
  const record = usage as Record<string, unknown>;
  const input = record["prompt_tokens"];
  const output = record["completion_tokens"];
  if (typeof input !== "number" || typeof output !== "number") return null;
  return { inputTokens: input, outputTokens: output };
};

/** Token counts from a complete (non-streamed) chat-completions JSON body. */
export const extractUsageFromJson = (body: string): Usage | null => {
  try {
    return usageFromObject(JSON.parse(body));
  } catch {
    return null;
  }
};

const scanSseForUsage = async (stream: ReadableStream<Uint8Array>): Promise<Usage | null> => {
  const decoder = new TextDecoder();
  let buffered = "";
  let found: Usage | null = null;
  const reader = stream.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    buffered += done ? decoder.decode() : decoder.decode(value, { stream: true });
    const lines = buffered.split("\n");
    // The last element is an incomplete line (or "") — keep it buffered.
    buffered = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;
      const payload = line.slice("data: ".length).trim();
      if (payload === "" || payload === "[DONE]") continue;
      try {
        // With include_usage, every chunk carries usage: null except the
        // final one — usageFromObject returns null until that one arrives.
        found = usageFromObject(JSON.parse(payload)) ?? found;
      } catch {
        // Partial or non-JSON data line — not ours to police; passthrough
        // already delivered it to the client verbatim.
      }
    }
    if (done) return found;
  }
};

const accumulateJsonForUsage = async (stream: ReadableStream<Uint8Array>): Promise<Usage | null> => {
  const decoder = new TextDecoder();
  let text = "";
  const reader = stream.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    text += done ? decoder.decode() : decoder.decode(value, { stream: true });
    if (text.length > MAX_JSON_ACCUMULATION_BYTES) {
      await reader.cancel();
      return null;
    }
    if (done) return extractUsageFromJson(text);
  }
};

/**
 * Tee an upstream response stream: the returned stream is handed to the
 * client untouched; the sibling branch is scanned for the usage block and
 * resolves once the stream ends (null when no usage ever appeared).
 */
export const teeUsage = (
  stream: ReadableStream<Uint8Array>,
  contentType: string,
): { stream: ReadableStream<Uint8Array>; usage: Promise<Usage | null> } => {
  const [passthrough, scanned] = stream.tee();
  const usage = (contentType.includes("text/event-stream") ? scanSseForUsage(scanned) : accumulateJsonForUsage(scanned)).catch(
    () => null,
  );
  return { stream: passthrough, usage };
};

export interface UsageReport {
  readonly subdomain: string;
  readonly selectionId: string;
  readonly model: string;
  readonly usage: Usage | null;
  readonly ok: boolean;
}

/** Report a completed call to Rails. One retry; never throws. */
export const reportUsage = async (rails: RailsHttpService, secret: string, report: UsageReport): Promise<void> => {
  const body = JSON.stringify({
    selection_id: report.selectionId,
    model: report.model,
    input_tokens: report.usage?.inputTokens ?? 0,
    output_tokens: report.usage?.outputTokens ?? 0,
    status: report.ok ? "ok" : "error",
  });
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await rails.request({
        method: "POST",
        subdomain: report.subdomain,
        path: RECORD_USAGE_PATH,
        headers: buildHeaders(body, secret),
        body,
        timeoutMs: 10_000,
      });
      if (response.statusCode < 500) return;
    } catch {
      // fall through to retry
    }
  }
  log.warn({ event: "record_usage_failed", selection_id: report.selectionId });
};
