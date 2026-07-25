# Collective Settings Re-architecture + AI Setup Flow

> **Shipped** in full: phases 1–2 via PR #518 (merged 2026-07-21), phases 3–4 via 04563162 (2026-07-21: agent-setup pointer, checkout copy, settings slim-down).

## Problem

Two intertwined problems, one root cause.

**The setup journey is clunky.** Creation → working AI takes four dependent
steps (upgrade to paid → enable Trio → open a funding pool → members top up
credits and enroll) spread across three pages, with the dependency knowledge
living only in help docs. Failures:

- After creating a collective: empty homepage, no next-step pointer.
- Upgrade CTA buried at the bottom of settings; its success flash doesn't point
  at Trio or the pool.
- Trio is one anonymous checkbox in a feature-flag list. Enabling it activates
  personas that **cannot run** on a billing tenant without a pool, and nothing
  says so — `ensure_personas_funded!` silently no-ops.
- A member who @mentions a persona in that state gets *nothing*; the dispatch
  error lands only on the task-run page. Mentioning where Trio isn't enabled
  sends a notification (`notification_dispatcher.rb`); there's no analogue for
  "enabled but unfunded."
- Members have no navigation path to `{collective}/pool`, the only place they
  can enroll (linked only from admin-only settings and from /billing's
  funding section, which renders only once already enrolled).
- Enrolling without prepaid credits surfaces a raw validation message with no
  top-up button and no return path back to the pool page.
- The two Stripe checkouts (owner's $3/mo subscription vs. one-time credit
  top-ups) are never distinguished at the point of need.

**The settings page is a god-page.** ~628 lines, nine concerns, four
interaction models (god save-form, immediate `button_to`s, three inline forms,
a Stimulus section), three audiences — including one *personal* action
(Withdraw from Pool) on a page only admins reach. Structural costs: the pool
ceiling form POSTs to `update_settings`, forcing the partial-params dance; the
pool section duplicates the member pool page (two renderings drifting
independently); agent removal has two parallel paths (`remove_ai_agent` in
settings vs. `remove_member` on Members, which already works on agents).

## Design

Organizing principle: **split by intent; one canonical surface per
*operation*.** Read-only summaries may repeat across pages; every mutating
affordance has exactly one home.

### Page architecture (target state)

**`{collective}/settings` — configuration only.**
Image, name, description, timezone, tempo, synchronization mode, permissions,
free feature flags, and the non-agent paid features (file attachments with its
storage usage/limit UI). One form, one Save. Plus an owner-only "Plan" section
— **the permanent home of upgrade/downgrade**: the paid tier gates
automations, file attachments, and future non-agent features (custom roles,
media upload), so plan lifecycle is collective-level, not agent-level. Plus
the danger zone (archive). No pool section, no agent membership section, no
operational buttons inside the save-form.

**`{collective}/pool` — the single pool surface, for everyone.**
Keeps today's member view (enroll, withdraw, transparency tables). Gains the
admin controls now in settings, rendered conditionally: open/reopen with
ceiling, change ceiling, attach/detach member agents, close. This includes
**wind-down mode** — when a pool exists but `funding_pools_available?` is
false (lapse, downgrade), the pool page must offer admins close/detach
alongside the member notice, or a lapsed collective's admin loses the ability
to close their pool. Warnings like "not running: principal not enrolled"
appear here where both audiences see them.

**`{collective}/agents` — new first-class page: "what runs here, who pays for
it, is it healthy?"**
Member-visible, admin controls conditional (same pattern as pool). Covers ALL
agent members — copy says "agents" generically; "built-in" only on the Trio
card:

- Plan gate: if free on a billing tenant, an upgrade pointer linking the same
  canonical `upgrade_preview` flow settings links — a pointer, not a second
  upgrade surface. Copy frames the paid plan as unlocking Trio *among other
  features*.
- Trio as a real feature card: enable/disable (admin), the three persona
  profiles/run links, and a funding status line — including the load-bearing
  warning: "Trio is enabled but can't run: no funding pool. Open one →".
- Pool summary card (open? N enrolled? ceiling?) linking to the pool page.
- Member agents: identity, principal, funded-by status (membership
  *operations* live on Members). No automations section — automations keep
  their own home at settings/automations rather than a count repeated here.

Behavior matrix: billing tenant + free tier → renders with the upgrade gate
(the page is the funnel's front door); billing tenant + paid → full page;
non-billing tenant → full page, no plan gate. **Private workspaces have no
`/agents` page** — the workspace assistant stays in user settings.

**`{collective}/members` — the roster, uniformly humans and agents.**
Answers "who belongs and what may they do." Gains *add your agent to this
collective*, gated by `can_invite?` — anyone who can invite a human can add
their own agent. (Placement next to Invite is layout, not equivalence:
invites require acceptance; agent-adding is a direct add with the principal
consenting on the agent's behalf.) Keeps role management for all member
types. Remove-from-collective becomes the **single removal path** for agents
too: `remove_ai_agent` and its Stimulus `ai_agent-manager` controller are
deleted after confirming `remove_member` covers its cases (funded-agent
state, archived memberships).

The members/agents split is by **question, not population** — agents stay on
the roster (agents-are-members is a deliberate commitment). An agent appears
on both pages; no operation is duplicated.

### Funnel connective tissue

- **Post-creation:** collective homepage shows admins a compact "finish
  setting up" pointer (→ Agents page) while the funnel is incomplete (paid but
  no Trio, Trio but no pool, pool but zero enrollments). Disappears when done
  or dismissed.
- **Flash chaining:** each step's success flash links the next. Upgrade →
  "enable Trio on the Agents page." Trio enabled → "Melody, Counterpoint, and
  Cadence joined — they need a funding pool to run. Open one →." Pool opened →
  "Members can now enroll" links the pool page.
- **Enabled-but-unfunded notification:** the analogue of the existing
  Trio-not-enabled mention notification, scoped precisely to the
  **dispatch-time no-pool gate** (`AgentRunnerDispatchService`:
  collective-principaled + billing tenant + no `funding_pool_id`). When a
  mention-triggered run fails there, notify the mentioner with the reason and
  the pool link. Deduped once per person per collective per condition
  *transition*: it can fire again only after a pool was opened and later
  closed/lapsed, not on a timer. Out of scope: "pool exists but
  can't pay" (zero enrollments / empty balances) fails per-call inside the
  LLM gateway, not at dispatch — that belongs to the zero/low-balance
  notifications thread (LLM Gateway open item 2.2).
- **Member-visible pool link:** collective homepage kebab menu, with the other
  page links (settings, members, …).
- **Enrollment credits path:** the pool page states the credits prerequisite
  up front for un-enrolled members without credits, with a top-up button that
  round-trips — /billing top-up carries `return_to` back to the pool page
  (the checkout-return path already supports it).
- **Checkout distinction copy:** where the two payments meet (upgrade preview,
  pool page, /billing), one line each distinguishing the $3/mo plan from
  prepaid usage credits.

### Dual interface (markdown views + actions routes)

Verified inventory: `.md.erb` twins exist for settings, pool, show, new,
join, index, backlinks; **`members.md.erb` does not exist** (agents see the
roster via `show.md.erb`; member role/remove *actions* exist without a page
view). Historically pool ops were split: `pool/actions` carried only
enroll/withdraw; admin pool ops lived under `settings/actions`.

**No route compatibility burden** (settled with Dan): no agents currently
depend on the settings-prefixed pool routes, so they are deleted, not
aliased. One page owns one responsibility; a route's prefix says which page
owns it.

Obligations:

- **Pool consolidation:** every pool operation — page, plain form endpoints,
  and describe/execute actions (enroll, withdraw, attach, detach, plus
  create/close/ceiling) — lives only under `{collective}/pool/...`. The
  settings-prefixed pool routes (plain POSTs and actions) are removed, and
  the settings actions index stops listing pool actions.
- **Ceiling leaves `update_collective_settings`:** the pool draw ceiling is
  pool responsibility, so it becomes a described pool action; the settings
  action no longer accepts ceiling params.
- **Agents page:** net-new `agents.html.erb` + `agents.md.erb` + actions index
  + an explicit Trio enable/disable action.
- **Trio's second door stays open:** `update_collective_settings` can already
  set the trio flag; both it and the new Agents-page action funnel into the
  flag + `PersonaActivator.reconcile!` — the flag stays the single source of
  truth. The HTML checkbox is what's replaced, not the settings-action
  capability.
- **Members add-agent:** `add_ai_agent_to_collective` moves to a
  `members/actions` home; add `members.md.erb` when the page gains the
  affordance, keeping HTML and markdown symmetric.
- Help docs updated: `/help/trio` ("settings → Features Enabled" → Agents
  page), `/help/funding-pools`, `/help/collectives`.

### Controller cleanup (falls out of the split)

- Pool actions move out of `CollectivesController` (~1300 lines) into a
  `FundingPoolsController`; existing route paths keep working (aliases above).
- Ceiling changes get their own endpoint; `update_settings` drops the
  `member_daily_draw_cap` branch and its partial-params juggling.
- The Trio HTML toggle moves off the generic feature-flag save path to an
  explicit Agents-page action (still driving flag + `reconcile!`).
- `settings` stops loading pool/agent state it no longer renders.

## Phasing

Each phase ships independently, leaves no dead UI, and keeps interim
cross-links so no path disappears before its replacement exists (e.g. Phase 1
leaves a one-line settings → pool pointer until Phase 4 builds the final
settings layout).

**Phase 1 — Pool consolidation + the notification.** Move admin pool controls
(incl. wind-down mode) to `{collective}/pool`; delete the settings pool
section (leave the pointer); extract `FundingPoolsController`; separate
ceiling endpoint; `pool/actions` re-homes; enrollment credits round-trip
(`return_to`); member-visible pool links (homepage kebab, members page). Plus
the enabled-but-unfunded dispatch notification — its link target exists
today, it has no Agents-page dependency, and it's the highest-value item in
the plan.

**Phase 2a — Agents page, additive.** New `{collective}/agents` (HTML + md +
actions index): Trio card with explicit toggle action, funding warnings, pool
summary, member-agent display, automations link. Nothing removed from
settings yet.

**Phase 2b — Migration off settings.** Remove the Trio checkbox and the agent
membership section from settings; add-agent (+ `members/actions` home +
`members.md.erb`) moves to Members; retire `remove_ai_agent`; flash chaining
(destinations now stable); help-doc updates.

**Phase 3 — Funnel feedback polish.** Post-creation "finish setting up"
pointer; checkout-distinction copy.

**Phase 4 — Settings slim-down.** Plan section, danger zone, final save-form
pass (configuration + file-attachments only), controller diet for `settings`.

Testing per phase: red-green throughout; controller tests move/extend with
re-homed actions; update `test/manual/` checklists and e2e specs that
navigate the reorganized sections.

## Out of scope

- Pool mechanics, ceilings, draw policy, the visibility rule.
- Zero/low-balance and pool-can't-pay notifications (LLM Gateway item 2.2).
- Onboarding wizards / multi-step modals — the Agents page's resting state is
  the checklist.
- Main-collective settings and private-workspace surfaces, beyond keeping
  them rendering correctly as sections move.
- Collective-level group chat (parked separately).
