#!/usr/bin/env node
// Binary entry point. The actual dispatch lives in `runCommand` in ./cli
// so it stays importable and side-effect-free for tests. This file is what
// `package.json` `bin.harmonic-bridge` points at.

import { runCommand } from "./cli.js";

runCommand(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err) => {
    process.stderr.write(`harmonic-bridge: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  },
);
