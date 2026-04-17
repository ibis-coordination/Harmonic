import { describe, it, expect } from "vitest";
import { Effect, Layer } from "effect";
import { retryOnTransient } from "../../src/services/TaskReporter.js";
import { HarmonicApiError } from "../../src/errors/Errors.js";

describe("retryOnTransient", () => {
  it("does not retry on 4xx errors", async () => {
    let attempts = 0;
    const effect = retryOnTransient(
      Effect.suspend(() => {
        attempts++;
        return Effect.fail(new HarmonicApiError({ message: "Not Found", statusCode: 404, path: "/test" }));
      }),
    );

    const result = await Effect.runPromiseExit(effect);
    expect(result._tag).toBe("Failure");
    expect(attempts).toBe(1);
  });

  it("retries up to 3 times on 5xx errors then fails", async () => {
    let attempts = 0;
    const effect = retryOnTransient(
      Effect.suspend(() => {
        attempts++;
        return Effect.fail(new HarmonicApiError({ message: "Internal Server Error", statusCode: 500, path: "/test" }));
      }),
    );

    const result = await Effect.runPromiseExit(effect);
    expect(result._tag).toBe("Failure");
    expect(attempts).toBe(4); // 1 initial + 3 retries
  });

  it("retries on connection errors (no statusCode)", async () => {
    let attempts = 0;
    const effect = retryOnTransient(
      Effect.suspend(() => {
        attempts++;
        return Effect.fail(new HarmonicApiError({ message: "Connection refused", path: "/test" }));
      }),
    );

    const result = await Effect.runPromiseExit(effect);
    expect(result._tag).toBe("Failure");
    expect(attempts).toBe(4);
  });

  it("succeeds immediately if first attempt works", async () => {
    let attempts = 0;
    const effect = retryOnTransient(
      Effect.suspend(() => {
        attempts++;
        return Effect.succeed("ok");
      }),
    );

    const result = await Effect.runPromise(effect);
    expect(result).toBe("ok");
    expect(attempts).toBe(1);
  });

  it("succeeds if a retry attempt works", async () => {
    let attempts = 0;
    const effect = retryOnTransient(
      Effect.suspend(() => {
        attempts++;
        if (attempts < 3) {
          return Effect.fail(new HarmonicApiError({ message: "Bad Gateway", statusCode: 502, path: "/test" }));
        }
        return Effect.succeed("recovered");
      }),
    );

    const result = await Effect.runPromise(effect);
    expect(result).toBe("recovered");
    expect(attempts).toBe(3);
  });

  it("does not retry on 409 Conflict", async () => {
    let attempts = 0;
    const effect = retryOnTransient(
      Effect.suspend(() => {
        attempts++;
        return Effect.fail(new HarmonicApiError({ message: "Conflict", statusCode: 409, path: "/test" }));
      }),
    );

    const result = await Effect.runPromiseExit(effect);
    expect(result._tag).toBe("Failure");
    expect(attempts).toBe(1);
  });
});
