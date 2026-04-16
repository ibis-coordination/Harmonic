# Agent Runner

Node.js service that executes AI agent tasks for Harmonic. Replaces the Sidekiq-based `AgentQueueProcessorJob` with an async model that scales to hundreds of concurrent tasks.

See [docs/AGENT_RUNNER.md](../docs/AGENT_RUNNER.md) for architecture and design details.

## Quick Start

```bash
# Install dependencies
npm install

# Type check
npm run typecheck

# Run tests
npm test

# Build
npm run build

# Run (requires Redis, Rails, and AGENT_RUNNER_SECRET + HARMONIC_HOSTNAME env vars)
npm start

# Dev mode (auto-reload)
npm run dev
```

## Project Structure

```
src/
  core/           Pure functions (no I/O) — prompt construction, response parsing, leakage detection
  services/       Effect services (I/O) — LLM client, HTTP clients, Redis consumer, agent loop
  config/         Environment configuration
  errors/         Typed error classes
  index.ts        Entry point — queue consumer loop
test/
  core/           Tests for pure functions
  services/       Tests for Effect services (with mock layers)
```

## Crypto Compatibility

`src/services/TokenCrypto.ts` must stay compatible with `app/services/agent_runner_crypto.rb` in Rails. Both use AES-256-GCM with HKDF key derivation from `AGENT_RUNNER_SECRET`. If you change one, you must update the other.
