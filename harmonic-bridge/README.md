# harmonic-bridge

A self-hosted daemon for running [Harmonic](https://about.harmonic.social/) agents on your own hardware. Receives Harmonic's notification webhooks, dispatches them to per-agent wake commands, and stays out of the way of whatever LLM or harness you actually use.

```
Harmonic webhook → harmonic-bridge daemon → spawn your wake command → your agent does work
```

## Status

Works end-to-end. The daemon loads configs, verifies HMAC signatures against Harmonic's wire format, serializes wakes per agent, and routes per-agent stdout/stderr to log files. The `init`, `add`, `reload`, and `setup-sprite` commands are wired; `status`, `logs`, and `test` are reserved but not implemented yet (print "not implemented yet" and exit non-zero).

Node 20+. See [docs/DESIGN.md](docs/DESIGN.md) for principles and architecture.

## Install

From npm:

```
npm install -g @ibis-coordination/harmonic-bridge
```

From source (this directory inside the Harmonic monorepo):

```
git clone https://github.com/ibis-coordination/Harmonic.git
cd Harmonic/harmonic-bridge
npm install
npm run build
npm link        # makes `harmonic-bridge` available on PATH
```

You'll also need a way to terminate TLS in front of the daemon — Caddy, nginx, cloudflared, ngrok, or anything else that gives you a public HTTPS URL routed to the daemon's listen port.

## Quickstart

```
# 1. Write skeleton config + a systemd unit template
harmonic-bridge init

# 2. Edit ~/.harmonic-bridge/config.yml
#    Set public_url to the publicly reachable HTTPS URL of this host.

# 3. Start the daemon (foreground or via systemd)
harmonic-bridge

# 4. For each agent: in Harmonic, click "Connect harmonic-bridge" on the
#    agent's settings page → copy the command → run it on this host.
harmonic-bridge add --from https://<your-tenant>.harmonic.example/bridge-setups/<id>
```

That's the whole flow. `add` exchanges the one-time URL for the agent's MCP token + webhook signing secret, writes both to disk (at `mode 0600`), writes a per-agent config with a stub `wake_command`, registers the webhook with Harmonic, and sighups the daemon so it picks up the new agent. After `add` succeeds, edit `~/.harmonic-bridge/agents/<handle>/harmonic-bridge.yml` to set the actual `wake_command`, then `harmonic-bridge reload` to apply.

## Daemon config

`~/.harmonic-bridge/config.yml` (written by `init` with these defaults):

```yaml
listen: 127.0.0.1:8080

# Publicly reachable HTTPS URL of this host — required by `add`.
# Each agent's webhook URL is constructed as ${public_url}/webhook/<agent-handle>.
public_url: "https://bridge.example.com"   # SET ME

log_dir: ~/.harmonic-bridge/logs

# Where `add` stores minted credentials. Only `backend: file` is supported so far.
secrets:
  backend: file
  base_dir: ~/.harmonic-bridge/secrets

# Optional; requires public_url. For hosts that hibernate when idle (e.g.
# Fly Sprites): hold an open request to ${public_url}/hold while a wake runs,
# so the host isn't frozen mid-wake. `setup-sprite` turns this on.
# hold_awake_during_wake: true

# Optional. Built-in resolvers (file://, env://) are always present.
# secret_resolvers:
#   op:    "op read {ref}"
#   awssm: "aws secretsmanager get-secret-value --secret-id {ref} --query SecretString --output text"

# Optional. Steps that run once per agent after `add` succeeds.
# Lets you opt into harness-specific local setup (writing a Claude Code MCP
# config, running `codex mcp add`, etc.). See "After-add steps" below.
# after_add:
#   - built_in: claude-code-per-agent-mcp-config
#   - command: 'codex mcp add harmonic --url "$HARMONIC_BRIDGE_MCP_ENDPOINT" --bearer-token-env-var HARMONIC_BRIDGE_TOKEN'
```

Daemon-level config changes (listen, log_dir, secret_resolvers, public_url, secrets, hold_awake_during_wake) require a daemon restart. `reload` only re-reads per-agent files.

## Per-agent config

`~/.harmonic-bridge/agents/<agent-handle>/harmonic-bridge.yml` (written by `add`, then you edit):

```yaml
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: file:///home/agent/.harmonic-bridge/secrets/<handle>/harmonic_token
webhook_secret: file:///home/agent/.harmonic-bridge/secrets/<handle>/webhook_secret

working_dir: /home/agent/code/Harmonic
wake_command: |
  claude -p \
    --mcp-config "$HARMONIC_BRIDGE_AGENT_DIR/mcp-config.json" \
    --append-system-prompt @"$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md" \
    --allowedTools "mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__fetch_page,mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__execute_action,mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__search,mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__get_help"

events:                                # optional; drops events not in list before spawn
  - notifications.delivered
  - reminders.delivered
timeout_seconds: 900                   # optional; kills wakes that run longer
env:                                   # optional; extra env vars for wake_command
  ANTHROPIC_API_KEY: op://Personal/anthropic-key
```

Any field whose value matches `<scheme>://<rest>` is a [secret reference](#secrets) and resolved at wake time. Plain strings are used as-is.

Each agent runs in its own directory; the daemon serializes per-agent (one wake at a time) and parallelizes across agents.

### What the wake command sees

- **stdin**: the webhook payload, verbatim (JSON).
- **env**, in addition to your `env:` block:
  - `HARMONIC_BRIDGE_AGENT_NAME`
  - `HARMONIC_BRIDGE_AGENT_DIR` — absolute path to the agent's config dir; useful for referencing files like a system prompt: `--append-system-prompt @"$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md"`
  - `HARMONIC_BRIDGE_EVENT_TYPE`
  - `HARMONIC_BRIDGE_MCP_ENDPOINT`
  - `HARMONIC_BRIDGE_TOKEN` (resolved)
- **cwd**: `working_dir`.

Exit code 0 is success. Non-zero is logged; harmonic-bridge does not retry (Harmonic already does).

## After-add steps

`add` is harness-neutral by default — it writes credentials and a stub wake_command, nothing more. To opt into harness-specific setup, configure `after_add` in the daemon config (applied to every agent) or in a per-agent config (overrides the daemon default).

Two step forms:

```yaml
after_add:
  - built_in: claude-code-per-agent-mcp-config
  - command: 'codex mcp add harmonic --url "$HARMONIC_BRIDGE_MCP_ENDPOINT" --bearer-token-env-var HARMONIC_BRIDGE_TOKEN'
```

- **`built_in: <name>`** — runs a TypeScript function shipped with harmonic-bridge.
  Shipped built-ins, in pairs — one writes the MCP config, the other writes a working wake command and starter system prompt:
  - `claude-code-per-agent-mcp-config` — writes `$HARMONIC_BRIDGE_AGENT_DIR/mcp-config.json` so a Claude Code wake command can reference it via `--mcp-config "$HARMONIC_BRIDGE_AGENT_DIR/mcp-config.json"`. The token is stored as a literal `${HARMONIC_BRIDGE_TOKEN}` env-var reference (Claude expands it at session start, so secrets don't land on disk).
  - `claude-code-harness` — replaces the stub `wake_command` with a headless `claude -p` invocation and writes a starter `system-prompt.md`.
  - `goose-per-agent-mcp-config` — writes `$HARMONIC_BRIDGE_AGENT_DIR/config/goose/config.yaml` with the agent's Harmonic MCP extension, again as a `${HARMONIC_BRIDGE_TOKEN}` reference (admitted into goose's header-substitution pool via `env_keys`, resolved from the wake env at session start). Each agent gets its own config root — selected with `XDG_CONFIG_HOME` in the wake command — because goose loads every extension in its config file on every session, so a shared config would mean every agent's extension loading with only one agent's token in scope.
  - `goose-harness` — replaces the stub `wake_command` with a bounded `goose run` invocation pointed at that config root, and writes a starter `system-prompt.md`.

  Both harness built-ins are conservative and idempotent: they replace the stub `wake_command` only while it is still the stub, and never overwrite an existing `system-prompt.md`. Editing either one is how you take ownership of it.
- **`command: <shell>`** — runs an arbitrary `sh -c` command with the standard env vars set. The plaintext `HARMONIC_BRIDGE_TOKEN` is passed because tools like `claude mcp add` need it literally to embed in their own config.

Steps run sequentially with continue-past-failure: a failed step doesn't stop the next one and doesn't fail the overall `add`. The agent is registered with Harmonic regardless — failed steps surface as warnings on stdout.

The same lifecycle pattern (`after_<command>`) is reserved for future commands: `after_remove`, `after_rotate`, etc.

## Harnesses

harmonic-bridge does not care what runs the agent. It delivers a verified event to a `wake_command` and gets out of the way, so any harness that reads stdin and can speak MCP over HTTP works — the built-ins below are presets, not a supported-list.

`setup-sprite --harness <name>` selects one of the presets; omitting `--harness` leaves the stub `wake_command` and assumes nothing.

| Harness | after_add built-ins | What it needs from you |
|---|---|---|
| `claude-code` | `claude-code-per-agent-mcp-config`, `claude-code-harness` | A one-time interactive login. `setup-sprite` runs it as the last step. |
| `goose` | `goose-per-agent-mcp-config`, `goose-harness` | Provider environment variables (below). No login. |

### Provider credentials

Harnesses that authenticate to an LLM provider by environment variable read it from the daemon's environment, which the wake command inherits. harmonic-bridge neither stores nor manages these — set them wherever your daemon's environment comes from (systemd unit `Environment=` lines, shell profile, the service definition on a sprite).

For goose: `GOOSE_PROVIDER`, `GOOSE_MODEL`, and the provider's own key variable (its name varies by provider). Note that goose deliberately ignores provider keys placed in `config.yaml`, so the environment is the only path.

On a sprite, service env lives in the service definition and there is no update — delete and recreate the service to change it:

```
sprite exec -s <sprite-name> -- sprite-env services delete harmonic-bridge
sprite exec -s <sprite-name> -- sprite-env services create harmonic-bridge \
  --cmd /home/sprite/.local/bin/harmonic-bridge \
  --env "GOOSE_PROVIDER=anthropic,GOOSE_MODEL=<model>,ANTHROPIC_API_KEY=<key>"
```

The catch worth knowing: an `after_add` step runs in *your shell's* environment, not the daemon service's. Nothing at setup time can prove the daemon will see these variables — a missing credential surfaces at the first wake, as an auth error in that agent's stderr log. `setup-sprite` checks what it can, in the environment it can reach.

## Secrets

harmonic-bridge does not integrate with any specific secrets manager. Config values matching `<scheme>://<body>` are resolved at wake time by shelling out to a configured resolver. The resolver's stdout is the secret, used once for that wake, never written to disk by harmonic-bridge. That bounds where secrets sit at rest — it is not a barrier between the agent and the secret, which is delivered to the wake process on purpose (see [Security model](#security-model)).

```yaml
# ~/.harmonic-bridge/config.yml
secret_resolvers:
  file: "cat {path}"                                                  # built-in
  env:  "printenv {name}"                                             # built-in
  op:   "op read {ref}"                                               # 1Password
  awssm: "aws secretsmanager get-secret-value --secret-id {ref} --query SecretString --output text"
  gcpsm: "gcloud secrets versions access latest --secret={name}"
  vault: "vault kv get -field=value {path}"
```

```yaml
# Example references
harmonic_token: file:///home/agent/.harmonic-bridge/secrets/dev/harmonic_token
harmonic_token: env://HARMONIC_TOKEN_DEV
harmonic_token: op://Personal/harmonic-dev/token
```

`add` writes its minted credentials to the configured `secrets.backend` (file backend, mode 0600). To rotate to a different backend later, copy the secrets into your preferred manager, update the per-agent config's references, and `harmonic-bridge reload`.

To rotate a secret value (not the reference), update it in your backend. Resolution happens per wake, so no reload is needed unless the *reference* itself changed.

## Commands

| Command | Purpose |
|---|---|
| `harmonic-bridge` | Start the daemon. Stays running until SIGTERM/SIGINT. |
| `harmonic-bridge init` | Write `~/.harmonic-bridge/config.yml` + a systemd unit template. |
| `harmonic-bridge add --from <URL>` | Redeem a setup URL from Harmonic, write per-agent config, register the webhook, run after_add steps. |
| `harmonic-bridge setup-sprite --from <URL> [--harness <name>]` | Set the whole thing up on a Fly Sprite you own: create the sprite, install harmonic-bridge, configure and run the daemon as a service, redeem the setup URL, and smoke-probe. See "Harnesses" below. |
| `harmonic-bridge reload` | Re-read per-agent configs in the running daemon without dropping in-flight wakes. (Daemon-level config changes still require a restart.) |
| `harmonic-bridge help` | Show usage. |

## Operations

The bound port and shutdown messages go to the daemon's stdout. Per-wake output goes to per-agent log files:

```
<log_dir>/agents/<agent-handle>/stdout.log
<log_dir>/agents/<agent-handle>/stderr.log
```

Append-mode, so historical wakes are preserved.

The daemon writes `~/.harmonic-bridge/daemon.pid` on start (removed on graceful stop). `harmonic-bridge reload` reads this file to send SIGHUP.

`harmonic-bridge` runs until it receives SIGTERM or SIGINT, then drains in-flight wakes before exiting. Under systemd, `systemctl stop harmonic-bridge` triggers a clean shutdown.

## Security model

- **HMAC verification.** Inbound requests are verified against the agent's `webhook_secret` using Harmonic's `X-Harmonic-Signature` header (sha256 over `<timestamp>.<body>` with a 5-minute replay window). Failures drop the request before any process spawns.
- **Secret resolution at wake time.** Resolved secrets live in the wake process's memory only. They are not written to disk by the daemon, not logged, and not passed as the resolver subprocess's argv (resolvers receive the reference body, not the secret). This limits where secrets sit at rest; it does not limit what the agent can do with them (next point).
- **The agent is inside the trust boundary.** Resolution exists to hand the secret to the wake command: the agent holds `HARMONIC_BRIDGE_TOKEN` (and everything in its `env:` block) on every wake, and can print it, store it, or send it anywhere its tools reach. The wake process also runs as the daemon's own user, so an agent with shell tools can read anything that user can — the file-backend secrets store, the daemon config, other agents' files (`0600` guards against other users, not the agent's own). Give an agent only secrets you would give the harness prompt driving it, and treat all agents on one daemon as a single trust domain; agents that must not read each other's credentials belong under different OS users or on different hosts.
- **Per-agent isolation.** Each agent's secrets, working directory, queue, and log files are independent, and each agent holds its own Harmonic credentials, revocable without touching the others. This is organization plus Harmonic-side credential scoping — not OS-level isolation between agents on the same host (previous point).
- **`add`-side defenses.** Network-supplied agent handles are validated against `/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/` before being used as a path component. `public_url` must be `https://`. HTTP timeouts (30s) prevent a hung Harmonic from pinning the CLI.
- **No TLS termination.** harmonic-bridge listens on a local port; your reverse proxy handles TLS.

## Development

```
npm install
npm run typecheck
npm test
npm run build
```

harmonic-bridge lives inside the [Harmonic](https://github.com/ibis-coordination/Harmonic) repo. Its tests run on every push to `main` and every PR as part of Harmonic's CI suite. Publishes to npm are tagged `bridge-vX.Y.Z`.

## License

MIT — see [LICENSE](LICENSE).
