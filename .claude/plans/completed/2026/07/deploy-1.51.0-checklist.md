# Deploy checklist — 1.51.0

Covers the eight PRs merged since v1.50.0 (#495, #501, #502, #504, #505,
#507, #508, #510). Four migrations run in this deploy, two of which carry
fail-fast namespace guards — the pre-deploy section exists to make sure
they pass on the first try.

Migration order:

1. `20260716074003` (#502) — five nullable receipt columns on
   `llm_usage_records`. No backfill, no guard.
2. `20260716120000` (#504) — backfills system agents' `parent_id` to their
   collective's identity user.
3. `20260717090000` (#508) — backfills the `trio` persona role, renames
   legacy trio handles to `trio-[collective_handle]`, drops
   `collectives.trio_user_id`. **Guard**: aborts listing offenders if any
   non-trio user or any collective holds a `trio`/`trio-*` handle.
4. `20260717130000` (#510) — retires legacy trio agents in place (roles
   stripped, memberships archived, rules disabled, pool detached; User
   rows kept for attribution) and renames the `trio_unavailable`
   notification-pref key to `persona_unavailable`. **Guard**: aborts if
   any handle sits in the `melody`/`counterpoint`/`cadence` namespaces,
   exempting rows held by the matching system agent.

(The three rewritten 2026-05 migrations are tombstones — no-ops on prod's
already-run chain; they only fail fast if replayed against a pre-rename
backup.)

## 1. Pre-deploy

### Retire the prod external melody agent (required — guard tripwire)

The bridge-VM melody's `melody` handle trips migration 4's guard **by
design**. In order:

- [ ] Wind down the DigitalOcean bridge VM / Cloudflare tunnel
      (`bridge1.3ibis.com`) so the agent stops polling.
- [ ] Archive the melody agent user in prod (its API tokens die with it).
- [ ] Archive the `melodic-agent` GitHub repo (long-standing open item).
- [ ] Note the retirement in the ops log.

### Scan prod for other namespace offenders

- [ ] Run against prod (psql or console) and resolve anything it returns
      before deploying (rename, or archive if it's the external melody):

```sql
SELECT 'tenant_users' AS src, tenant_id, handle FROM tenant_users
 WHERE handle ~ '^(trio|melody|counterpoint|cadence)(-.*)?$'
UNION ALL
SELECT 'collectives', tenant_id, handle FROM collectives
 WHERE handle ~ '^(trio|melody|counterpoint|cadence)(-.*)?$';
```

Expected hits that are FINE: legacy trio users' `trio`/`trio-<hex4>`
handles (migration 3 renames them; migration 4 retires them). Anything
else — a user or collective squatting any of the four namespaces — must
be resolved by hand first; the guards will list `(tenant_id, handle)`
pairs if you miss one.

### Environment variables

- [ ] Remove `TRIO_DEFAULT_MODEL`.
- [ ] Set `MELODY_DEFAULT_MODEL`, `COUNTERPOINT_DEFAULT_MODEL`,
      `CADENCE_DEFAULT_MODEL`. On the **sandbox (billing) tenant** these
      must be gateway-resolvable (`provider/model` per
      `StripeGatewayModelMapper`, or unset → gateway default) — LiteLLM
      aliases fail dispatch fast there. The main tenant still routes via
      LiteLLM until its `stripe_billing` cutover, so aliases still work
      for it.

### Know the economics before you flip it

- [ ] Sandbox-tenant trio collectives: built-in agents on billing tenants
      are pool-or-nothing (#504). Any sandbox collective with Trio
      enabled but no open funding pool gets fast dispatch failures
      pointing at collective settings — expected, but know which
      collectives that is (funding-pool-smoke has a pool).
- [ ] Trio-enabled collectives go from one pool spender to **three**.
      Existing enrollments legally cover "the collective's agents", but
      no member notification fires (open product question). Decide
      whether to announce before or after.

## 2. Deploy

- [ ] `./scripts/deploy.sh --with-migrations` (migrations run in a
      one-off container from the new image before the app starts).
- [ ] If a guard aborts: read the listed `(tenant_id, handle)` pairs,
      resolve consciously, re-run. Nothing is mutated before the guard
      passes.

## 3. Post-migrate: seed the ensembles

Reconcile is lazy — it runs on a collective's next settings save. After
migration 4, trio-enabled collectives have **no active personas** until
reconciled. Force it from the console rather than waiting:

```ruby
Tenant.all.each do |t|
  Tenant.current_id = t.id
  Collective.tenant_scoped_only(t.id).find_each do |c|
    Collective.current_id = c.id
    PersonaActivator.reconcile!(c)
  end
ensure
  Tenant.current_id = nil
  Collective.current_id = nil
end
```

`reconcile!` is idempotent and a no-op where Trio is off, so running it
over every collective (workspaces included) is safe. This is the same
path verified on dev.

- [ ] Run the reconcile sweep.
- [ ] Spot-check one trio-enabled collective: three new members
      (`melody-*`, `counterpoint-*`, `cadence-*` handles), each holding
      persona + `trio` + capability roles, each attached to the pool
      (billing tenants), each with one mention-responder automation rule.

## 4. Verify

- [ ] Legacy trio agents dormant: membership archived, rules disabled,
      old posts still attributed to them, `trio-*` profile pages render.
- [ ] `@melody` / `@counterpoint` / `@cadence` each resolve and reply in
      an enabled collective; a `@trio` mention draws up to three replies
      and renders as a link to the collective.
- [ ] Mention a persona where Trio is OFF → `persona_unavailable`
      notification with the enable-Trio hint.
- [ ] `/help/trio` renders (HTML + markdown); `/u/trio` no longer
      resolves (expected — accepted consequence of #508).
- [ ] Sandbox: one end-to-end pool draw, then confirm the
      `llm_usage_records` row carries the #502 receipt
      (`funding_pool_enrollment_id` + both cap snapshots).
- [ ] Pool page (`/collectives/:handle/pool`): members/agents tables and
      the Maximum Possible Draw arithmetic render (#501).
- [ ] Grant `automator` to a non-admin member; they can manage
      automations (#505).
- [ ] Agent markdown settings page shows the Public writes line (#495).

## 5. Rollback notes

- App-only rollback: `rollback.sh` as usual.
- Migration 3 has a real `down` (recomputes `trio_user_id` from the
  role). Migrations 1–2 are trivially reversible. **Migration 4's `down`
  raises** — retirement is one-way; restoring legacy trio agents would
  mean hand-reversing roles/memberships/rules. Take the usual pre-migrate
  DB snapshot.
- Old backups predate the trio→persona rename; replaying migrations
  against one trips the tombstone guards on purpose. Restore code +
  data from the same era together.

## 6. Accepted consequences (don't page yourself)

- Old stored text mentioning hex handles (`@trio-a1b2c3d4`) is dead text;
  bare `@trio` re-resolves on render and keeps working.
- Customized automation rules on legacy trio agents are orphaned with
  them; fresh uniform defaults seed instead (inherent to net-new cadence).
- Main-collective personas get `<persona>-<32hex>` handles (main
  collectives have random hex handles) — ugly, accepted.
