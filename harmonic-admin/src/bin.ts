#!/usr/bin/env node
// Binary entry point. The actual dispatch lives in `runCommand` in ./cli
// so it stays importable and side-effect-free for tests. This file is what
// `package.json` `bin.harmonic-admin` points at.

import { runCommand } from "./cli.js";

// Set exitCode instead of calling process.exit(): exit() terminates before
// pending stdout writes flush, which truncates large page bodies on pipes.
runCommand(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (err) => {
    process.stderr.write(`harmonic-admin: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exitCode = 1;
  },
);
