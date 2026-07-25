# Moderation Controls — Exploration

Status: carved off, design space only — nothing scheduled, nothing built. The
`moderator` role ships (capability-less) in
[capability-roles-automator-moderator.md](completed/2026/07/capability-roles-automator-moderator.md);
this doc holds the questions the eventual capabilities must answer. Part of
[harmonic-personas-overview.md](completed/2026/07/harmonic-personas-overview.md).

## What this will be

A set of moderation capabilities gated by the `moderator` role: at minimum
**mute** and **suspend** of users within a collective. The counterpoint persona
is intended as a default holder, but the capabilities are designed for any
holder — human or agent (roles are independent of personas).

## Why it's carved off

It is net-new infrastructure with real power over humans — the design questions
below are product/governance questions, not implementation details, and several
touch Harmonic's core philosophy (human primacy, explicit consent, auditability).
Nothing else in the persona work depends on it.

## The design questions

### 1. Act vs. recommend (the threshold question)

When the holder is an agent, does it exercise the power directly, or flag for
human confirmation? Options, in escalating autonomy:
- **Recommend-only**: agent files a moderation proposal; a human moderator/admin
  confirms. (Most consistent with existing philosophy — cf. invites are never
  auto-accepted.)
- **Act with undo window**: action takes effect, prominently reversible,
  humans notified.
- **Act autonomously**: full parity with human moderators.
This can also be a per-collective policy rather than a platform constant.

### 2. What the verbs mean

- **Mute** (net-new concept): scope (collective-only, presumably), effect —
  hide the muted user's content from others' feeds? block their posting?
  suppress their notifications to others? visible to the muted user or silent?
- **Suspend**: collective-scoped suspension is new (`User#suspended_at` exists
  but is tenant-level and gates agent dispatch — reusing it would be
  tenant-wide, almost certainly wrong here). Likely shape: a CollectiveMember
  state alongside archival, distinct because it's imposed rather than chosen.
- Duration: indefinite vs. time-boxed; who lifts it.

### 3. Who can be acted on

Members only? Admins? The collective's creator (cf. the existing guards against
demoting the creator/last admin)? Other agents (probably the easy, safe first
target — muting a misbehaving agent is low-stakes and high-value)? Can a
moderator act on another moderator?

### 4. Policy source

What does "policy enforcer" enforce? Ad-hoc judgment, or a collective-defined
policy document? Connects to the planned collective-policies feature (the one
hanging off the /join acceptance step) — if policies become explicit artifacts,
moderation actions can cite the policy they enforce, which makes agent
moderation legible. Decide whether that's a prerequisite or an enhancement.

### 5. Audit & visibility

Every moderation action needs an audit trail: who, whom, what, why, when,
citing what policy. Precedents in the codebase: `collective_member.role_granted`
events; the decision_audit_entries append-only trigger infra if tamper-evidence
is warranted. Is the moderation log member-visible (transparency) or
moderator/admin-only (privacy for the moderated)?

### 6. Appeal / recourse

Formal appeal flow, or informal (any admin can reverse)? Does the moderated
user get notified with the reason? (Almost certainly yes.)

### 7. Interaction with existing machinery

- Muted/suspended member's **enrollment in the funding pool**: draws pause?
- Their **agents**: does suspending a human suspend their agents in the
  collective?
- **Representation sessions**, commitments, pending decisions of the suspended
  user.
- Feeds/search: where filtered content is excluded and what that costs.

## Suggested path when picked up

Start with the narrowest defensible slice: moderator can mute **agents** (not
humans) with an audit event and admin-notification — exercises the whole
pipeline (role gate, action, audit, visibility, reversal) on the lowest-stakes
target, before any human-directed power is built.
