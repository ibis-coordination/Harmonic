# Codex harness for harmonic-bridge

Add `codex` as a second supported harness, at parity with `claude-code`: an
`after_add` built-in that turns a freshly-added agent into a working Codex agent,
and a `setup-sprite --harness codex` path that wires it up on a Fly Sprite.

## What exists today (the shape to match)

The Claude Code path is three pieces:

1. `src/claude-mcp-config.ts` — built-in step `claude-code-per-agent-mcp-config`.
   Writes `$AGENT_DIR/mcp-config.json` with the token as a literal
   `${HARMONIC_BRIDGE_TOKEN}` env reference, so the secret never hits disk.
2. `src/claude-code-harness.ts` — built-in step `claude-code-harness`. Replaces the
   stub `wake_command` (only if it still contains the stub marker), sets
   `timeout_seconds: 900` if absent, and writes `system-prompt.md` with `wx`.
   Both writes are conservative → the step is idempotent and safe on every add.
3. `src/setup-sprite.ts` — the `HARNESSES` registry entry: `afterAdd` step names,
   an in-sprite `authCheckScript`, an interactive `authCommand`, and
   `authInstructions`. Auth runs last, after the agent is already connected.

Registry wiring is in `src/steps.ts` (`BUILT_INS`). Harness neutrality is a stated
design property: without `--harness`, nothing is assumed.

## Codex CLI research

Sources: [non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode),
[config reference](https://learn.chatgpt.com/docs/config-file/config-reference),
[developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli),
[MCP](https://learn.chatgpt.com/docs/extend/mcp),
[auth flows](https://codex.danielvaughan.com/2026/04/01/codex-cli-authentication-flows-credential-management/),
[config hierarchy & trust](https://codex.danielvaughan.com/2026/04/16/codex-cli-configuration-complete-guide-hierarchy-profiles-trust/),
[Sprites quickstart](https://docs.sprites.dev/quickstart/).

**Headless invocation.** `codex exec` is the non-interactive mode. It accepts three
stdin shapes; the one that matches harmonic-bridge is *prompt argument + piped
stdin*: the argument is the instruction, the piped content is context. That maps
cleanly onto our `claude -p --append-system-prompt @file` + JSON-payload-on-stdin
split — no new plumbing in `spawn.ts`.

**Relevant flags.** `-s/--sandbox {read-only|workspace-write|danger-full-access}`,
`-a/--ask-for-approval {untrusted|on-request|never}`, `--skip-git-repo-check`,
`-c/--config key=value` (repeatable, dotted keys, values parse as TOML if
possible else literal string), `--ignore-user-config`, `--cd/-C`, `--model`,
`--json`, `-o/--output-last-message`. `--full-auto` is deprecated in favor of
`--sandbox workspace-write`.

**No tool allowlist.** Codex has no `--allowedTools` analogue; the sandbox mode
plus approval policy is the whole permission surface. The wake command is
therefore shorter than Claude's in that dimension.

**MCP.** Streamable HTTP servers are configured under `[mcp_servers.<name>]` with
`url` and `bearer_token_env_var` (the named env var is sent as the `Authorization`
bearer). Also available: `http_headers`, `env_http_headers`, `enabled`,
`required`, `startup_timeout_sec`, `tool_timeout_sec`. `codex mcp add <name>
--url <url> --bearer-token-env-var <VAR>` writes this into
`$CODEX_HOME/config.toml`. In `exec` mode, servers start and stop with the
session; `required = true` makes a failed server abort the run instead of
silently continuing without tools.

**Config precedence.** CLI flags and `-c` overrides > `--profile` > project
`.codex/config.toml` > user `$CODEX_HOME/config.toml`. `CODEX_HOME` (default
`~/.codex`) holds `config.toml`, `auth.json`, logs, sessions.

**Trust gates project config.** A project-scoped `.codex/config.toml` loads *only*
if the directory is marked trusted, and `--skip-git-repo-check` explicitly does
*not* confer trust. So "drop a `.codex/config.toml` in the agent dir" is not a
viable per-agent config mechanism without a separate global trust write.

**Instructions.** `model_instructions_file` *replaces* built-in instructions (too
blunt); `developer_instructions` injects extra instructions; `AGENTS.md` is
discovered from cwd but is also trust-gated. Passing our prompt as the `codex
exec` prompt argument avoids all three.

**Auth.** `auth.json` lives in `$CODEX_HOME` and moves with it. Three modes:
browser OAuth (needs localhost:1455 — unusable headless), `codex login
--device-auth` (prints a code, approve on any device — the headless path, but a
ChatGPT *workspace* admin must have enabled device-code login), and
`codex login --with-api-key` reading the key from stdin (`printenv OPENAI_API_KEY |
codex login --with-api-key`). Tokens refresh and are written back to `auth.json`.
`codex login status` exits 0 when logged in — a real check, better than a file test.

**Sprites.** The Sprites base image ships Codex preinstalled alongside Claude Code
and Node — no install step needed, subject to the PATH check below.

**Container sandbox caveat.** Codex's Linux sandbox uses Landlock/seccomp, which
fails in some containers ("the combination of seccomp/landlock … is not supported
in this environment"). Workarounds are `use_legacy_landlock = true` or letting the
container be the boundary with `--sandbox danger-full-access`. Sprites are Fly
micro-VMs with a real kernel, so `workspace-write` most likely works — but this is
the single most important thing to verify empirically before shipping the sprite path.

## Design decisions

**D1. Per-agent MCP config via `-c` overrides, sharing `~/.codex` for auth.**
*Decided.* The wake command carries the server definition inline:

```
-c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.url=\"$HARMONIC_BRIDGE_MCP_ENDPOINT\""
-c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.bearer_token_env_var=\"HARMONIC_BRIDGE_TOKEN\""
-c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.required=true"
```

Consequences: one `codex login` per host serves every agent, so `harmonic-bridge
add` yields a working agent with no interactive step; nothing is written outside
the agent dir; no config file to keep in sync. `HARMONIC_BRIDGE_TOKEN` is already
in the wake env and is only ever named, never inlined — same secret posture as the
Claude path. Server name `harmonic-<handle>` is a valid TOML bare key given the
handle regex `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`.

Rejected alternatives:
- *Per-agent `CODEX_HOME`* (`$AGENT_DIR/codex-home/config.toml`, written by a
  `codex-per-agent-config` built-in). Cleaner wake command and symmetric with the
  Claude pair of built-ins, but `auth.json` moves with `CODEX_HOME`, so every
  agent needs its own interactive login — `add` stops being one-shot. Symlinking
  `auth.json` back to `~/.codex` is not safe: Codex writes refreshed tokens back,
  and an atomic replace would silently break the link.
- *Project `.codex/config.toml` in the agent dir.* Trust-gated; needs a global
  `projects."<path>".trust_level` write anyway.
- *Global `codex mcp add` as a `command:` step.* Every agent's server would land in
  the shared `~/.codex/config.toml` with identical URLs and the same env var name,
  so every Codex session on the box would load N duplicate servers.

**D2. Do not pass `--ignore-user-config`.** The operator's own `config.toml` (model
choice, provider, `use_legacy_landlock`) is usually wanted, and our `-c` overrides
and flags win anyway. Note in docs: if the operator previously ran the
`/help/mcp/connect/codex` flow, a `harmonic-<handle>` server may already exist
globally; the `-c` override targets the same key and simply wins.

**D3. Sandbox `workspace-write`, approval `never`, `--skip-git-repo-check`.**
`working_dir` defaults to the agent's config dir, which is not a git repo, so the
git check must be skipped. `workspace-write` lets the agent do real work in its
own directory without the container-escape blast radius of `danger-full-access`.
If D3 fails inside a Sprite (see verification), the fallback is documented rather
than silently widened.

**D4. Instructions as the prompt argument, payload on stdin.** `codex exec
"$(cat "$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md")"` with the JSON event piped
in. Avoids `AGENTS.md` / `model_instructions_file` / trust entirely and keeps the
file layout identical to the Claude harness (`system-prompt.md` in the agent dir,
user-editable).

**D5. Auth in the sprite: `codex login --device-auth`.** Mirrors the existing
`claude /login` shape (interactive, runs last, verified afterwards). Check script
should be `codex login status` if `codex` resolves on PATH for `sprite exec`;
otherwise `test -f /home/sprite/.codex/auth.json`. The failure message must name
the two known escapes: workspace admins must enable device-code login, and
`printenv OPENAI_API_KEY | codex login --with-api-key` is the automation path.

**D6. Share the system prompt body between harnesses.** The Claude and Codex
prompts differ in exactly one paragraph (the tool inventory). Extract the shared
body into `src/harness-system-prompt.ts` taking a harness-specific tools
paragraph, rather than forking a near-duplicate 20-line string.

**D7. Harness selector on the bridge-setup page.** The copyable sprite command
becomes selector-driven rather than hardcoding one harness. Shape:

- The controller builds the base command without `--harness` plus the list of
  supported harnesses (`claude-code`, `codex`) — a single source of truth for the
  slugs, since it must stay in step with `setup-sprite`'s `HARNESSES` registry.
- HTML view: a small Stimulus controller swaps the `--harness <slug>` suffix in
  the `<pre>` and in the copy button's payload as the selection changes. "None"
  is a valid selection and emits the command with no flag, preserving today's
  harness-neutral path.
- Markdown view (`show.md.erb`) has no interactivity: list both commands as peers,
  since an agent reading this page needs to see the options, not a widget.
- The hint text stops naming one harness and describes the flag generically, with
  the per-harness detail (which login each hands off to) alongside each option.

## Concrete wake command

```
codex exec \
  --skip-git-repo-check \
  --sandbox workspace-write \
  --ask-for-approval never \
  -c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.url=\"$HARMONIC_BRIDGE_MCP_ENDPOINT\"" \
  -c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.bearer_token_env_var=\"HARMONIC_BRIDGE_TOKEN\"" \
  -c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.required=true" \
  "$(cat "$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md")"
```

Plus `timeout_seconds: 900` when absent, same as the Claude harness.

## System prompt deltas

Reuse the Claude body verbatim except:

- Tool inventory paragraph → Codex's shell and file-editing tools instead of
  `Bash,Read,Write,Edit,Glob,Grep,WebFetch`.
- Note that MCP tools appear namespaced by server (`harmonic-<handle>`), so
  `fetch_page` / `execute_action` may be prefixed.
- Keep the "your stdout is not visible to anyone — the only way to be seen is
  `execute_action`" framing. It applies identically: Codex prints its final
  message to stdout and progress to stderr, both of which go to the agent's log
  files.

## Implementation

Red-green per step; each is its own commit.

Steps 1 and 6 are shared with the Goose harness — whichever ships first pays for
them, and the second inherits both. If the Goose harness has already landed, skip
step 1 (the shared prompt module exists) and step 6 (the selector exists), and
add only the Codex entries.

1. **Extract the shared prompt** (D6). New `src/harness-system-prompt.ts`;
   `claude-code-harness.ts` consumes it. Existing
   `claude-code-harness.test.ts` assertions must stay green unchanged — that's the
   proof the refactor is behavior-preserving.
2. **`src/codex-harness.ts` + `src/codex-harness.test.ts`.** Mirror the Claude
   harness tests: replaces the stub, leaves a customized `wake_command` alone,
   writes `system-prompt.md` only when absent, sets `timeout_seconds` only when
   absent, preserves the generated YAML's comments (`parseDocument`), and is
   idempotent across two runs. Assert the emitted command contains the three
   `-c` overrides, `--skip-git-repo-check`, and no literal token.
3. **Register `codex-harness` in `BUILT_INS`** (`src/steps.ts`), with a
   `steps.test.ts` case asserting the name resolves.
4. **`setup-sprite --harness codex`.** New `HARNESSES` entry. Tests in
   `setup-sprite.test.ts` mirroring the claude-code ones: the rendered daemon
   config contains `codex-harness` and no Claude references; the auth check runs
   after `add`; a failed auth returns non-zero with the device-code + API-key
   guidance; the unknown-harness error lists both harnesses.
5. **PATH check for the sprite service** (see verification). If `codex` does not
   resolve for `sprite exec` / services — the same nvm-bin problem that forced the
   `harmonic-bridge` symlink into `~/.local/bin` — add the equivalent symlink step
   to the codex harness path in `setup-sprite.ts`, with a test.
6. **Harness selector on the bridge-setup page** (D7). Rails-side, its own commit
   with controller and view tests.

Run `npm test` and `npm run typecheck` in `harmonic-bridge/` for steps 1–5, and
the targeted Rails test files for step 6.

## Verification (must do before shipping the sprite path)

Local results 2026-07-27 (codex-cli 0.146.0-alpha.3.1 bundled in Codex.app,
sharing the desktop app's `~/.codex/auth.json`, against dev Harmonic):

1. ✅ Prompt argument + piped stdin — the piped JSON reached the model as
   context and was acted on.
2. ✅ Dotted `-c mcp_servers.…` overrides registered the server;
   `bearer_token_env_var` picked the token from the wake env;
   `fetch_page /whoami` returned the right agent.
3. ⏳ Sprite-bound: macOS sandboxes via Seatbelt, so `workspace-write` passing
   locally proves nothing about Landlock/seccomp in a sprite.
4. ✅ No approval stall — with a version finding: **`codex exec` on this build
   rejects `--ask-for-approval` outright**; the wake command now carries
   `-c 'approval_policy="never"'` instead, which this build accepts silently
   and stable documents. Exec ran shell + MCP work unattended either way.
5. ⏳ Sprite-bound (PATH for `sprite exec` / services; codex is in the base
   image, and `codex login status` doubles as the probe).
6. ⏳ Sprite-bound + Dan-paced (workspace device-code gating).
7. ⏳ Post-publish (the in-sprite install pulls the published package), same as
   the goose sequencing.

## Docs and release

- `harmonic-bridge/README.md` — the built-ins list is already stale: it documents
  only `claude-code-per-agent-mcp-config`, missing `claude-code-harness`, and the
  command table has no `setup-sprite` row. Fix both while adding `codex-harness`,
  and document `--harness claude-code|codex`.
- `app/views/help/self_hosting_agents.md.erb` — the `--harness` paragraph names
  only `claude-code`; extend to both.
- `app/views/ai_agent_bridge_setups/show.html.erb` and `show.md.erb`, and
  `app/controllers/ai_agent_bridge_setups_controller.rb:39` (which hardcodes
  `--harness claude-code` in `@sprite_setup_command`) — replaced by the selector
  in D7.
- `harmonic-bridge/package.json` — minor bump (0.2.3 → 0.3.0), publish tagged
  `bridge-vX.Y.Z`.
- CHANGELOG after merge, not in the feature-branch commits.

## Open questions

None blocking. The one thing that could force a redesign is verification item 3
(Landlock/seccomp inside a Sprite); if `workspace-write` is rejected there, decide
between `use_legacy_landlock = true` and `danger-full-access` scoped to the sprite
path before writing the `HARNESSES` entry.
