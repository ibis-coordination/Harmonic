# Help topics: single source of truth + discovery

## Problem

Three places own pieces of the help-topic list, and nothing checks they agree:

1. **`HelpController::TOPICS`** — the actual list. Decides which `/help/<topic>` routes resolve.
2. **`app/views/help/index.md.erb`** — hand-maintained markdown bullets with one-line descriptions. Silently drifts when a topic is added or removed.
3. **`agent-runner/src/core/AgentContext.ts`** — a hardcoded duplicate in the `get_help` tool's `topic` description ("Available: collectives, notes, ..."). Stale today; missing `representation`, `notifications`, `automations`, `billing`, `trio`, `mcp`. An agent asked about a missing topic confidently reports it doesn't exist.

Sub-pages (`/help/agents/getting-started`, `/help/agents/representation`) compound the issue — they have their own controller actions and view files but no presence in TOPICS or any registry an agent can query.

A secondary issue: agent-runner's `get_help` schema marks `topic` as **required**, while Rails' MCP `get_help` accepts no-arg calls to return the index. The "call with no topic to discover" path the Rails side documents doesn't work through agent-runner.

## End state

**Principle:** Rails owns the topic list. Agent-runner has zero topic knowledge. Agents discover topics at runtime by calling `get_help` with no argument, the same way they discover anything else in Harmonic.

Concretely:

- One source of truth in Ruby. The index page is **rendered from** the source — never hand-maintained.
- Agent-runner's `get_help` tool description names no specific topics and makes `topic` optional. Discovery happens through the index, fetched live.
- Sub-pages are addressable by name through `get_help` (e.g. `get_help("agents/representation")`), so agents can reach them without knowing the URL.
- A drift test on the Rails side fails CI when the file system, TOPICS, and rendered index get out of sync.

## Tasks

1. **Enrich TOPICS into a manifest.** Today it's a flat array of strings. Make it a structured list (or a Hash keyed by name) with: display title, one-line description, audience tag (human / agent / both), optional feature flag, optional parent topic. Keep `TOPICS.map(&:to_s)` available for the existing route-defining loop, or update that loop in the same pass.
2. **Generate the index from the manifest.** Replace the hand-maintained bullets in `app/views/help/index.md.erb` with an ERB loop over the manifest. Group by section (Foundations / Primitives / Discovery / Agency & Integration / etc.) via a section tag on each manifest entry. Render feature-gated entries conditionally as today.
3. **Register sub-pages as namespaced topics.** Add `"agents/getting-started"` and `"agents/representation"` (and any future audience-scoped pages) to the manifest with parent tags. Update route definitions so `/help/agents/getting-started` resolves through the same TOPICS machinery as top-level topics. Sub-pages render under their parent in the index.
4. **Strip the hardcoded list from agent-runner.** `agent-runner/src/core/AgentContext.ts`'s `get_help` schema:
   - Make `topic` optional (remove from `required`).
   - Description: "Read Harmonic documentation. Pass a topic name to read that topic, or call with no `topic` to get the index of available topics."
   - `topic` field description: "Topic name (e.g. 'notes', 'representation'). Omit to get the index."
   - No topic names enumerated.
5. **Drift test in the Rails suite.** Asserts:
   - Every `app/views/help/*.md.erb` (top-level, plus `app/views/help/agents/*.md.erb`) has a TOPICS entry, or is explicitly exempted (partials, fixtures).
   - Every TOPICS entry has a corresponding view file.
   - The rendered `/help` index lists every non-feature-gated topic exactly once.
6. **Verify discovery from an agent's perspective.** A test that hits `/mcp` with `tools/call get_help { topic: nil }` and asserts every TOPICS entry's title appears in the response body. Catches "index generator silently drops a topic" failures.
7. **Update the MCP `get_help` tool description if needed** so it matches the agent-runner side. (Currently Rails already says "Omit to get the index.")

## Tests

- `test/services/help_topics_manifest_test.rb` (new) — validates the manifest structure: every entry has the required fields, every name is unique, feature-flag values resolve.
- `test/integration/help_topics_drift_test.rb` (new) — the file-system vs. manifest vs. index drift assertions in Task 5.
- `test/controllers/mcp/endpoint_controller_test.rb` (extend) — the agent-perspective discovery assertion in Task 6.
- `agent-runner/test/core/AgentContext.test.ts` (extend) — assert `get_help` schema has no `required` array containing `topic` and no topic names in the description.

## Open questions

- **Manifest as Ruby vs. YAML.** A Ruby constant is closest to current state; a YAML file under `config/` is easier to scan and edit. Ruby keeps the freedom to declare procs (e.g. dynamic display-name overrides). Lean: Ruby until there's a reason to externalize.
- **Section grouping.** The current index groups topics under section headers. Encode sections as manifest tags (`section: "primitives"`) or as outer Hash keys (`{ "Primitives" => [...] }`)? Lean: tags — flat manifest is easier to iterate and lint.
- **Sub-page route shape.** Today `/help/agents/getting-started` is a bespoke controller action. Folding it into the TOPICS-driven route loop needs the route to accept slashes in the topic name (constraint: `topic` matches `[a-z\-/]+`). Alternative: keep bespoke routes but add the entries to the manifest for index/discovery only.
- **agent-runner build coordination.** The fix in agent-runner is independent of the Rails work — it can ship first if useful, since "no hardcoded topics" is always correct regardless of how Rails owns the manifest.

## Not in scope

- Localization or i18n of topic names / descriptions.
- Per-tenant topic overrides.
- A separate help-search facility (the existing `search` tool covers content; the index covers discovery).
- Rewriting individual topic page content.
- Renaming existing topics — keep names stable to avoid breaking links and saved references.

## Done when

- An agent calling `get_help` with no argument receives an index listing every topic currently exposed by Rails, with no possibility of an agent-runner-side stale list contradicting it.
- Adding a new topic requires exactly two file changes (one manifest entry + one view file). The drift test fails if either is missing.
- The agent-runner build no longer carries any reference to specific Harmonic topic names.
