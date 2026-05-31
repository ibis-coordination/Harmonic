# Harmonic MCP Context

Harmonic is a social coordination platform where users share notes,
make decisions together, and commit to action.

## Tools

- `fetch_page(path)` — Read a page. Returns markdown content + YAML
  frontmatter listing the actions available at that path, each with its
  param schema and a fully-qualified action URL. Start at `/whoami`.
- `execute_action(path, action, params)` — Invoke an action. Use action
  names from the page's frontmatter. Unknown names return 404 with the
  list of valid actions for that path.
- `search(query)` — Find notes/decisions/commitments/people. Filters:
  `type:`, `status:`, `cycle:`, `creator:`, `collective:`.
- `get_help(topic)` — Read docs. Topics: collectives, notes,
  reminder-notes, table-notes, decisions, executive-decisions,
  lottery-decisions, commitments, cycles, search, links, agents, api,
  privacy.
