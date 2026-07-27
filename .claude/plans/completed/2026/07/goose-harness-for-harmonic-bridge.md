# Goose harness for harmonic-bridge

Add `goose` as a supported harness at parity with `claude-code`: an `after_add`
built-in that turns a freshly-added agent into a working Goose agent, and a
`setup-sprite --harness goose` path.

Goose is the first harness with **no interactive login step** — its provider
credential is an environment variable, so `add` and `setup-sprite` complete
without a human-paced auth handoff.

## Prior art

The Claude Code path is the shape to match: `claude-mcp-config.ts` (built-in
writing a per-agent MCP config, token as a `${HARMONIC_BRIDGE_TOKEN}` reference
so the secret never hits disk), `claude-code-harness.ts` (built-in replacing the
stub `wake_command` only when the stub marker is present, setting
`timeout_seconds` if absent, writing `system-prompt.md` with `wx` — conservative
on both, therefore idempotent), and the `HARNESSES` registry in
`setup-sprite.ts`. Built-ins register in `BUILT_INS` in `steps.ts`.

## Goose CLI research

Sources: [CLI commands](https://goose-docs.ai/docs/guides/goose-cli-commands/) ·
[providers](https://goose-docs.ai/docs/getting-started/providers/) ·
[config files](https://goose-docs.ai/docs/guides/config-files/) ·
[extension types](https://deepwiki.com/block/goose/5.3-extension-types-and-configuration) ·
[Sprites quickstart](https://docs.sprites.dev/quickstart/).

- **Headless.** `goose run` with `-i, --instructions <FILE>` (`-` means stdin) and
  `--system <TEXT>` as a separate system-instruction slot. Cleaner than either
  incumbent: payload to stdin, harness prompt to `--system`, neither smuggled
  inside the other.
- **Unattended guardrails.** `--no-session`, `-q/--quiet`, `--max-turns <N>`
  (upstream default 1000), `--max-tool-repetitions <N>`, `--output-format`. No
  other supported harness bounds turns or tool-call loops. On a hibernating host
  that is load-bearing — a looping wake holds the machine awake and billing.
- **Tools are opt-in.** Shell and file tools come from the `developer` builtin
  extension, requested with `--with-builtin developer` or enabled in config. A
  config carrying only the Harmonic extension yields an agent with *no* local
  tools.
- **MCP extensions.** `extensions` key, `type: streamable_http` (underscore — the
  hyphenated form is silently wrong), `uri`, and a `headers` map. Header values
  support `${VAR}` substitution **only from the extension's `envs`/`env_keys`
  pool, not the raw process env** (verified against 1.44.0 source and live);
  `env_keys` names are looked up environment-first, so listing
  `HARMONIC_BRIDGE_TOKEN` there pulls it from the wake env. The CLI's
  `--with-streamable-http-extension <URL>` has no header support, so the config
  file is the only path.
- **Provider credentials are environment variables.** `GOOSE_PROVIDER`,
  `GOOSE_MODEL`, and the provider's own key var. Goose deliberately does **not**
  read provider keys from `config.yaml` — a key placed there is ignored. So
  relocating Goose's config tree strands no credentials.
- **Config location.** `$HOME/.config/goose/config.yaml` on macOS and Linux;
  `XDG_CONFIG_HOME` overrides it on both (verified — it wins even against a
  divergent `HOME`), which is the per-agent relocation mechanism.
- **Sprites.** Goose is **not** in the base image (Claude Code, Codex, and Gemini
  CLI are), so the sprite path needs an install step the others don't.

## Design decisions

**D1. Per-agent config via a relocated config root.** A built-in writes
`$AGENT_DIR/config/goose/config.yaml`; the wake command exports
`XDG_CONFIG_HOME="$AGENT_DIR/config"`. Goose honors it alone on macOS and Linux
(verified), so `HOME` stays untouched and the agent keeps the daemon user's real
dotfiles — gitconfig, ssh — for shell work. Safe here in a way it would not be
for Codex: Goose keeps no credentials in its config tree, so this moves
configuration only, and it matches the daemon's per-agent isolation property
rather than working against it.

```yaml
extensions:
  harmonic-<handle>:
    enabled: true
    type: streamable_http
    name: harmonic-<handle>
    uri: <mcp endpoint>
    headers:
      Authorization: "Bearer ${HARMONIC_BRIDGE_TOKEN}"
    env_keys:
      - HARMONIC_BRIDGE_TOKEN
    timeout: 300
```

*Rejected:* writing into the operator's shared `~/.config/goose/config.yaml`.
Every agent's extension would load in every session while only the current wake's
token is in scope, so the rest fail to authenticate on every run.

**D2. Provider credentials stay the operator's, supplied by environment.** The
bridge does not invent a config surface for LLM credentials — `GOOSE_PROVIDER`,
`GOOSE_MODEL`, and the provider key live in the daemon's (or sprite service's)
environment and inherit into the wake. Documented, not managed. This works on
every deployment including self-hosted Harmonic, which has no LLM gateway. A
later increment can supply these from a Harmonic-minted gateway token; that
changes which values are set, not the harness.

**D3. Instructions to `--system`, payload to stdin.**
`--system "$(cat "$AGENT_DIR/system-prompt.md")"` with the event JSON piped to
`-i -`. Keeps `system-prompt.md` user-editable in the agent dir, matching the
Claude Code layout.

**D4. Bounded by default.** `--no-session --quiet --max-turns 40
--max-tool-repetitions 3`, plus `timeout_seconds` on the agent config — turns
bound the loop, timeout bounds wall-clock, and they are complementary. The
numbers are starting points; the point is that the shipped default is bounded
rather than 1000 turns.

**D5. Local tools are explicit.** `--with-builtin developer` in the wake command
rather than enabled in the written config. It keeps the tool surface visible in
the command the operator reads and edits, and it is directly assertable in tests.
Without it the agent has only the four Harmonic MCP tools — which is a
defensible configuration, but not the one the system prompt describes.

**D6. No auth step in `setup-sprite` — install and preflight instead.** The
registry entry contributes an install step and a check that provider environment
is present, failing with the exact variable names if it isn't. There is no
interactive command and no credential file to test for, so
`authCheckScript` / `authCommand` / `authInstructions` do not apply.
`HarnessDefinition` gains optional fields rather than being forced into the login
shape, and `runSetupSprite`'s auth block must tolerate a harness that has none.

*Limitation:* the plain `add` path has no equivalent preflight — a step runs in
the CLI's environment, which is not the daemon service's. A missing provider
credential there surfaces at the first wake as a Goose auth error in the agent's
stderr log. Documented, not worked around.

**D7. Share the system prompt body across harnesses.** The Claude and Goose
prompts differ in one paragraph (the tool inventory). Extract the shared body
into `src/harness-system-prompt.ts` taking a harness-specific tools paragraph.
Whichever harness ships first pays for it; the next inherits it.

## Wake command

```
XDG_CONFIG_HOME="$HARMONIC_BRIDGE_AGENT_DIR/config" \
goose run \
  --no-session \
  --quiet \
  --max-turns 40 \
  --max-tool-repetitions 3 \
  --with-builtin developer \
  --system "$(cat "$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md")" \
  -i -
```

## System prompt deltas

Reuse the shared body, replacing the tool-inventory paragraph: shell and file
tools come from the `developer` extension, Harmonic tools from the
`harmonic-<handle>` extension. Keep the framing that stdout is invisible to
people and `execute_action` is the only way to be seen — `goose run` prints to a
log file nobody reads, so it holds identically.

## Implementation

Red-green per step, each its own commit. Steps 1 and 5's selector work are shared
with the Codex plan — whichever ships first pays, the second inherits.

1. **Extract the shared prompt** (D7). New `src/harness-system-prompt.ts`;
   `claude-code-harness.ts` consumes it. Existing Claude assertions must stay
   green unchanged — that is the proof the refactor preserves behavior.
2. **`src/goose-config.ts` + test.** Writes the per-agent config. Assert
   `type: streamable_http` (underscore), the `${HARMONIC_BRIDGE_TOKEN}` reference
   rather than a literal token, the `harmonic-<handle>` key, and idempotency.
3. **`src/goose-harness.ts` + test.** Mirror the Claude harness tests: replaces
   only the stub, leaves a customized `wake_command` alone, writes
   `system-prompt.md` only when absent, sets `timeout_seconds` only when absent,
   preserves the generated YAML's comments via `parseDocument`. Assert the command
   exports both `HOME` and `XDG_CONFIG_HOME` and carries the bounding flags and
   `--with-builtin developer`.
4. **Register both built-ins** in `BUILT_INS`, with a `steps.test.ts` case.
5. **`setup-sprite --harness goose`** (D6). Extend `HarnessDefinition`, add the
   registry entry, and confirm the auth block no longer assumes every harness has
   an interactive command. Tests: the rendered daemon config names the goose steps
   and no Claude ones; the install step runs; missing provider env fails with the
   variable names in the message; the unknown-harness error lists every harness.

`npm test` and `npm run typecheck` in `harmonic-bridge/` for each step.

## Verification

Results from the 2026-07-26 manual pass (goose 1.44.0; local macOS against dev
Harmonic, plus a throwaway x86_64 sprite for install/PATH/Linux checks):

1. ✅ **Fresh config root, env-only provider, no `goose configure`** — runs.
   D2's boundary holds.
2. ✅ `${HARMONIC_BRIDGE_TOKEN}` resolves and `fetch_page /whoami` succeeds —
   **but only after a design fix**: goose's header substitution draws from the
   extension's `envs`/`env_keys` pool, not the raw process env. The built-in now
   writes `env_keys: ["HARMONIC_BRIDGE_TOKEN"]`; goose's secret lookup checks
   the process environment first, so the value still comes from the wake env and
   never touches disk. Without `env_keys` the extension 401s **silently under
   `--quiet`** and the wake proceeds with no Harmonic tools.
3. ✅ `XDG_CONFIG_HOME` alone wins over a decoy `HOME` on macOS **and** Linux —
   so the `HOME` export was dropped, the agent keeps the daemon user's real
   dotfiles, and the config root moved to `$AGENT_DIR/config`.
4. ✅ Piped stdin is the instruction; `--system` is system context.
5. ✅ `--with-builtin developer` yields working shell/file tools alongside the
   Harmonic extension.
6. ✅ `download_cli.sh | CONFIGURE=false bash` works locally (macOS arm64) and
   in a sprite (linux x86_64); installs to `~/.local/bin`, which is already on
   PATH for non-login shells — no symlink needed.
7. ⚠️ `--max-turns` terminates promptly but exits **0**, so a turn-capped wake
   is indistinguishable from success in the daemon's exit-code log line.
8. ⏳ Still open: full webhook round-trip on a sprite (chat message → wake →
   `execute_action` reply) — needs a bridge-setup URL from a real tenant and a
   provider key in the sprite's service environment.

## Docs and release

- `harmonic-bridge/README.md` — the built-ins list is stale: documents only
  `claude-code-per-agent-mcp-config`, omits `claude-code-harness`, and the command
  table has no `setup-sprite` row. Fix all three while adding the goose built-ins,
  and document `--harness`.
- `app/views/help/self_hosting_agents.md.erb` — the `--harness` paragraph names
  only `claude-code`.
- The bridge-setup page hardcodes `--harness claude-code`; it needs the harness
  selector specified in the Codex plan, shared by both.
- Document the provider environment variables once, where both harnesses can
  point at it.
- `harmonic-bridge/package.json` minor bump, publish tagged `bridge-vX.Y.Z`.
  CHANGELOG after merge, not in feature-branch commits.

## Open questions

None blocking. Verification items 1–7 are resolved (see above); item 8 is the
remaining end-to-end check, paced by access to a real tenant.
