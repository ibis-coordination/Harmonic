import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BIN = path.join(HERE, "bin.ts");

// Run the bin entry as a real subprocess. Catches the kind of regression
// where the bin file silently exits because of a bad entry-point check —
// runCommand tests in cli.test.ts wouldn't notice that.

test("bin: 'help' prints usage and exits 0", async () => {
  const { stdout, stderr } = await execFileAsync(
    process.execPath,
    ["--import", "tsx", BIN, "help"],
  );
  assert.match(stdout, /Usage: harmonic-bridge/);
  assert.equal(stderr, "");
});

test("bin: unknown command exits non-zero and writes to stderr", async () => {
  await assert.rejects(
    () => execFileAsync(process.execPath, ["--import", "tsx", BIN, "no-such-cmd"]),
    (err: unknown) => {
      const e = err as { code: number; stderr: string };
      return e.code !== 0 && /unknown command/.test(e.stderr);
    },
  );
});

test("bin: 'init' with HARMONIC_BRIDGE_CONFIG_DIR=- still runs (via runCommand)", async () => {
  // This is a defensive smoke test: just make sure invoking the bin doesn't
  // silently no-op. The real init logic is covered by init.test.ts.
  await assert.rejects(
    () => execFileAsync(process.execPath, [
      "--import", "tsx", BIN, "init",
    ], { env: { ...process.env, HOME: "/nonexistent/no-such-home" } }),
    (err: unknown) => {
      // Init in a non-writable HOME should fail with non-zero, not exit 0.
      const e = err as { code: number };
      return e.code !== 0;
    },
  );
});
