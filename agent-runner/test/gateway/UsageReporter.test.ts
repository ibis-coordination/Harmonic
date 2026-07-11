import { describe, it, expect, vi } from "vitest";
import { extractUsageFromJson, teeUsage, reportUsage } from "../../src/gateway/UsageReporter.js";
import { log } from "../../src/services/Logger.js";
import type { RailsHttpService, RailsRequestOptions, RailsResponse } from "../../src/services/RailsHttp.js";

const chunkedStream = (chunks: string[]): ReadableStream<Uint8Array> => {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
};

describe("extractUsageFromJson", () => {
  it("reads token counts from a chat-completions body", () => {
    const body = JSON.stringify({
      id: "chatcmpl-1",
      choices: [{ message: { content: "hi" } }],
      usage: { prompt_tokens: 812, completion_tokens: 344, total_tokens: 1156 },
    });
    expect(extractUsageFromJson(body)).toEqual({ inputTokens: 812, outputTokens: 344 });
  });

  it("returns null when there is no usage block", () => {
    expect(extractUsageFromJson(JSON.stringify({ id: "chatcmpl-1" }))).toBeNull();
  });

  it("returns null for a non-JSON body", () => {
    expect(extractUsageFromJson("not json")).toBeNull();
  });
});

describe("teeUsage", () => {
  it("passes an SSE stream through unchanged and captures the final usage chunk", async () => {
    const sse = [
      'data: {"id":"c1","choices":[{"delta":{"content":"he"}}],"usage":null}\n\n',
      'data: {"id":"c1","choices":[{"delta":{"content":"y"}}],"usage":null}\n\n',
      'data: {"id":"c1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":7}}\n\n',
      "data: [DONE]\n\n",
    ];
    const { stream, usage } = teeUsage(chunkedStream(sse), "text/event-stream");

    const passthrough = await new Response(stream).text();
    expect(passthrough).toBe(sse.join(""));
    expect(await usage).toEqual({ inputTokens: 10, outputTokens: 7 });
  });

  it("captures usage when SSE lines are split across chunk boundaries", async () => {
    const line = 'data: {"id":"c1","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3}}\n\n';
    const { stream, usage } = teeUsage(
      chunkedStream([line.slice(0, 20), line.slice(20, 55), line.slice(55), "data: [DONE]\n\n"]),
      "text/event-stream",
    );

    await new Response(stream).text();
    expect(await usage).toEqual({ inputTokens: 5, outputTokens: 3 });
  });

  it("resolves null when an SSE stream never carries usage", async () => {
    const { stream, usage } = teeUsage(
      chunkedStream(['data: {"id":"c1","choices":[{"delta":{}}]}\n\n', "data: [DONE]\n\n"]),
      "text/event-stream",
    );

    await new Response(stream).text();
    expect(await usage).toBeNull();
  });

  it("scans a final usage line even without a trailing newline", async () => {
    const { stream, usage } = teeUsage(
      chunkedStream(['data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1}}']),
      "text/event-stream",
    );

    await new Response(stream).text();
    expect(await usage).toEqual({ inputTokens: 2, outputTokens: 1 });
  });

  it("propagates cancellation to the upstream source", async () => {
    // A disconnecting client must stop the upstream generation — with
    // stream.tee() the scanning branch kept pulling to EOF, holding the
    // upstream open (and billing tokens) after the client was gone.
    let cancelled = false;
    let chunks = 0;
    const encoder = new TextEncoder();
    const source = new ReadableStream<Uint8Array>({
      pull(controller) {
        chunks += 1;
        if (chunks <= 3) {
          controller.enqueue(encoder.encode('data: {"usage":null}\n\n'));
          return undefined;
        }
        // Stall like a slow upstream mid-generation.
        return new Promise<void>(() => {});
      },
      cancel() {
        cancelled = true;
      },
    });
    const { stream, usage } = teeUsage(source, "text/event-stream");

    await stream.getReader().cancel();

    expect(await usage).toBeNull();
    // Cancellation reaches the source through the pipe a tick later.
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(cancelled).toBe(true);
  });

  it("reads from the source only as fast as the consumer", async () => {
    // stream.tee() buffered every chunk the slower branch hadn't consumed,
    // unboundedly; the scanner must ride the consumer's pace instead.
    let pulls = 0;
    const encoder = new TextEncoder();
    const source = new ReadableStream<Uint8Array>(
      {
        pull(controller) {
          pulls += 1;
          if (pulls > 50) {
            controller.close();
            return;
          }
          controller.enqueue(encoder.encode('data: {"usage":null}\n\n'));
        },
      },
      { highWaterMark: 0 },
    );
    const { stream } = teeUsage(source, "text/event-stream");

    const reader = stream.getReader();
    await reader.read();
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(pulls).toBeLessThan(10);
  });

  it("parses a non-streamed JSON body at end of stream", async () => {
    const body = JSON.stringify({ id: "c1", usage: { prompt_tokens: 99, completion_tokens: 1 } });
    const { stream, usage } = teeUsage(chunkedStream([body.slice(0, 10), body.slice(10)]), "application/json");

    const passthrough = await new Response(stream).text();
    expect(passthrough).toBe(body);
    expect(await usage).toEqual({ inputTokens: 99, outputTokens: 1 });
  });
});

describe("reportUsage", () => {
  const railsCapture = (responses: number[]): { service: RailsHttpService; calls: RailsRequestOptions[] } => {
    const calls: RailsRequestOptions[] = [];
    const service: RailsHttpService = {
      request: async (opts): Promise<RailsResponse> => {
        calls.push(opts);
        const statusCode = responses[Math.min(calls.length - 1, responses.length - 1)] ?? 200;
        if (statusCode === 0) throw new Error("network down");
        return { statusCode, headers: {}, text: async () => "{}" };
      },
    };
    return { service, calls };
  };

  it("posts a signed record-usage payload", async () => {
    const { service, calls } = railsCapture([200]);

    await reportUsage(service, "test-secret", {
      subdomain: "app",
      selectionId: "sel_abc",
      model: "anthropic/claude-sonnet-4.6",
      usage: { inputTokens: 812, outputTokens: 344 },
      ok: true,
    });

    expect(calls).toHaveLength(1);
    expect(calls[0]?.path).toBe("/internal/llm-gateway/record-usage");
    expect(calls[0]?.subdomain).toBe("app");
    expect(calls[0]?.headers?.["X-Internal-Signature"]).toBeTruthy();
    expect(JSON.parse(calls[0]?.body ?? "{}")).toEqual({
      selection_id: "sel_abc",
      model: "anthropic/claude-sonnet-4.6",
      input_tokens: 812,
      output_tokens: 344,
      status: "ok",
    });
  });

  it("reports an upstream failure with zero tokens", async () => {
    const { service, calls } = railsCapture([200]);

    await reportUsage(service, "test-secret", {
      subdomain: "app",
      selectionId: "sel_err",
      model: "m",
      usage: null,
      ok: false,
    });

    expect(JSON.parse(calls[0]?.body ?? "{}")).toMatchObject({ selection_id: "sel_err", input_tokens: 0, output_tokens: 0, status: "error" });
  });

  it("logs a terminal 4xx rejection without retrying", async () => {
    // A systematic 401 (rotated secret) or 404 must leave a signal — silence
    // here means every ledger row quietly stays pending until someone audits.
    const warnSpy = vi.spyOn(log, "warn").mockImplementation(() => {});
    const { service, calls } = railsCapture([401]);

    await reportUsage(service, "test-secret", {
      subdomain: "app",
      selectionId: "sel_reject",
      model: "m",
      usage: { inputTokens: 1, outputTokens: 2 },
      ok: true,
    });

    expect(calls).toHaveLength(1);
    const entry = warnSpy.mock.calls
      .map((c) => c[0] as Record<string, unknown>)
      .find((f) => f["event"] === "record_usage_rejected");
    expect(entry).toMatchObject({ selection_id: "sel_reject", status_code: 401 });
    warnSpy.mockRestore();
  });

  it("retries once and never throws", async () => {
    const { service, calls } = railsCapture([0, 200]);

    await expect(
      reportUsage(service, "test-secret", {
        subdomain: "app",
        selectionId: "sel_retry",
        model: "m",
        usage: { inputTokens: 1, outputTokens: 2 },
        ok: true,
      }),
    ).resolves.toBeUndefined();
    expect(calls).toHaveLength(2);

    const failing = railsCapture([0, 0]);
    await expect(
      reportUsage(failing.service, "test-secret", {
        subdomain: "app",
        selectionId: "sel_gone",
        model: "m",
        usage: { inputTokens: 1, outputTokens: 2 },
        ok: true,
      }),
    ).resolves.toBeUndefined();
    expect(failing.calls).toHaveLength(2);
  });
});
