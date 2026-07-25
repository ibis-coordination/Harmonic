# Identity Glossary: cause · owner · acting identity

**Status: proposal (round 2), 2026-07-24.** Converges the identity vocabulary that
several plans invented independently for **the automation system**. Gates F5 of
[automations-mental-model-and-foundation.md](automations-mental-model-and-foundation.md);
intended as one of the first settled entries when `docs/CONTROLLED_VOCABULARY.md` exists
(per [simplified-technical-english-controlled-vocabulary.md](simplified-technical-english-controlled-vocabulary.md)).

## The three terms

Every identity question about an automation and its runs is one of exactly three
questions. Each gets one term, and no term answers more than one question.

### cause — *what fired it*

The occurrence that made a run happen: an event (with its actor), a schedule tick, an
inbound webhook delivery, or a manual invocation (with its invoking user). When the cause
carries a user — the event actor, the manual invoker — that user is the **cause actor**.
Scheduled and inbound-webhook runs have no cause actor.

Cause is attribution and audit **only**. It is never an input to authorization and never
an input to billing.

### owner — *who answers for the configuration*

Who answers for a piece of configuration (an automation rule, a persona, a notification
webhook): the **collective** for collective-owned config (answered for by its current
admins/automators), the **agent's principal** for agent-owned config, the **user** for
user-owned config.

Owner is a *resolvable role*, not a stored historical fact — it survives membership churn
and admin turnover. `created_by` remains as pure audit history ("who typed this in") and
must never be used to resolve ownership: creators leave collectives, and a collective's
rule is answered for by the collective, not by whichever admin happened to write the YAML.

### acting identity — *who it executes as*

The user an action executes as — the identity ActionsHelper authorizes and attribution
displays. The agent for agentic steps; the collective identity user for a collective
rule's internal actions; the `execute_as` on a ProposedAction. A rule can never do more
than its acting identity could do by hand.

## Out of scope: billing ("payer")

Billing is a **separate domain**, and the automation system has no billing concepts of
its own. The automation feature is covered by subscriptions (collective paid tier; the
per-identity notification-webhook fee), and when an automation triggers an agent task
run, that run's LLM usage is billed exactly like a manually triggered run: resolved in
the LLM-gateway domain from the *agent's* funding arrangement (funding pool, else the
run's stamped billing customer), where "payer" is already established vocabulary
(`LLMGateway::PayerResolver`).

The boundary rule for this glossary: **no automation concept — not the rule, not the
cause, not the owner — ever names or resolves a payer.** A design that wants a rule to
carry billing semantics (e.g. per-rule spending caps) is proposing a *limit* on the
automation side, not a payment concept; actual payment stays in the billing domain.

## The distinctions that carry weight

- **owner ≠ acting identity** — a collective rule *acts as* the collective identity user
  but is *answered for* by the collective (its admins/automators).
- **owner ≠ creator** — owner is resolvable now; creator is frozen history.
- **acting identity ≠ cause actor** — the agent acts; the mentioner merely caused.

## Mapping: what each plan and the code calls these today

| Concept | Term | [automations](automations-mental-model-and-foundation.md) | [decision-semantics](decision-semantics-and-action-approval.md) | [task-initiator](parked/task-initiator-resolution.md) | [trust-verification](agent-security-trust-verification.md) | Code today |
|---|---|---|---|---|---|---|
| what fired it | **cause** | cause | `proposed_by` (the proposal's cause) | `initiated_by` | provenance chain to originating event | `event.actor`; `AiAgentTaskRun#initiated_by` |
| answers for config | **owner** | owner | — | `responsible_party` (anchored to `rule.created_by`) | "trust level of the rule's **creator**" | `rule.created_by` (impure proxy) |
| executes as | **acting identity** | acting identity | `execute_as` | — | the agent | collective identity user / the agent |

## Conflicts this glossary resolves

1. **`responsible_party` (task-initiator plan) is superseded, not renamed.** That plan
   is speculative — not committed direction, possibly to be scrapped. It predates
   funding pools and the LLM gateway, which serve its billing motivation in the billing
   domain (the run's immutably stamped billing customer plus per-call `PayerResolver`
   resolution with pool receipts on the usage ledger). No `responsible_party` column
   should be added: it would be redundant on the individual-billing path and wrong on
   the pool path (no single user pays a pool-funded run). Its row in the mapping table
   above is historical vocabulary only; the sole live observation it leaves behind is
   the `initiated_by` impurity (item 3).
2. **Trust inheritance from the rule's "creator."** The trust-verification plan's
   automation row ("inherits trust level of the rule's creator") re-derives owner from
   frozen history. Automation-originated instructions carry the trust of the rule's
   **owner** — principal-level for agent rules, collective-governance-level for
   collective rules. Exact trust-level mapping stays that plan's business.
3. **`initiated_by`'s known impurity.** The automation executor falls back to
   `rule.created_by` when there is no event actor, because the column is not null. Under
   this glossary `initiated_by` means the *cause actor* and is honestly absent for
   scheduled/webhook runs. Fixing that (nullable column or an explicit trigger-source
   record) is a small standalone attribution cleanup — flagged here, not designed here.

## Rules of use

- New plans, code, and copy use these three terms for these three concepts — never
  "initiator," "responsible party," or "creator" (except `created_by` as literal audit
  columns).
- Billing vocabulary ("payer," customers, pools) stays in the billing domain; automation
  writing references it only across the boundary stated above.
- A design that needs a new identity concept adds a term here first; it does not
  overload one of these three.
