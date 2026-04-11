# Promo Codes

## Status

**Not started.** A previous implementation attempt was fully rolled back due to bugs around the interaction between `billing_exempt`, quotas, and subscription logic. See `memory/feedback_billing_promo_codes.md` for detailed lessons learned.

**Prerequisites now in place:**
- Per-entity `billing_exempt` on users and collectives (shipped)
- Cross-tenant billing model (shipped) — one subscription covers all billing-enabled tenants
- Centralized billing dashboard at `/billing` (shipped)
- Per-resource admin exemption toggle (shipped)

## Concept

Redeemable codes that grant free user accounts and/or quotas of free agents/collectives. Created by app admins. Can have expiration dates and usage limits.

### Example user journey

1. Admin creates promo code `BETA2026` with: free account + 2 free agents
2. User enters code on `/billing` page → account becomes exempt, user gets 2 free agent slots
3. User creates 2 agents → auto-exempted, no billing needed
4. User creates 3rd agent → normal billing confirmation required (quota exhausted)

## Key Design Constraints (from previous attempt)

The first implementation failed because of tangled concerns. These principles must guide the retry:

1. **One billing check, one place.** Extract all "can this user create/reactivate this entity?" logic into a single service method. No inline billing checks scattered across controllers.

2. **Separate concerns clearly:**
   - "Does this user need a subscription to use the app?" (gate bypass)
   - "Is this specific entity free?" (per-entity exemption)
   - "Can this user create more free entities?" (quota check)
   
   These must be three distinct methods, not tangled together.

3. **Quota is a first-class model, not derived from counting `billing_exempt` entities.** The previous approach of counting exempt entities as "used quota" led to deactivate/reactivate exploits. Consider a `PromoQuotaAllocation` model that explicitly tracks which entities consumed which quota slots.

4. **Don't skip billing logic for exempt users.** Exempt users should go through the same billing flow — the flow should compute a $0 charge. The `billing_exempt` flag should only affect the quantity calculation (0 vs 1 for the user's base), not bypass entire code paths.

5. **Write interaction tests first.** Before any implementation, write tests for the full matrix:
   - Exempt user + has quota + creates → free, auto-exempted
   - Exempt user + no quota + no subscription + creates → blocked
   - Exempt user + no quota + has subscription + creates → paid, confirmation required
   - Non-exempt user + has quota + creates → free, auto-exempted
   - Non-exempt user + no quota + creates → paid, confirmation required
   - Deactivate free entity → what happens to quota slot?
   - Reactivate when quota available → free
   - Reactivate when quota exhausted + no subscription → blocked
   - Reactivate when quota exhausted + has subscription → paid
   - Cross-tenant: quota applies across all billing-enabled tenants

## Data Model (revised)

### PromoCode

```
promo_codes
├── id (uuid, PK)
├── code (string, unique, not null)
├── name (string) — admin-facing description
├── created_by_id (uuid, FK → users)
├── free_account (boolean, default false) — grants billing_exempt on user
├── free_agent_quota (integer, default 0)
├── free_collective_quota (integer, default 0)
├── max_redemptions (integer, nullable) — nil = unlimited
├── redemption_count (integer, default 0)
├── expires_at (datetime, nullable) — nil = never expires
├── active (boolean, default true)
├── timestamps
```

### PromoCodeRedemption

```
promo_code_redemptions
├── id (uuid, PK)
├── promo_code_id (uuid, FK → promo_codes, not null)
├── user_id (uuid, FK → users, not null)
├── timestamps
```

Unique index on `[promo_code_id, user_id]` — each user can redeem a code only once.

### PromoQuotaAllocation (new — addresses previous bugs)

```
promo_quota_allocations
├── id (uuid, PK)
├── promo_code_redemption_id (uuid, FK → promo_code_redemptions, not null)
├── entity_type (string, not null) — "User" (for agents) or "Collective"
├── entity_id (uuid, not null) — the agent or collective that consumed this slot
├── timestamps
```

Unique index on `[entity_type, entity_id]` — each entity can only consume one quota slot.

**Why this model:** Instead of counting exempt entities to derive remaining quota, we explicitly track which entities consumed which slots. Deactivating an entity does NOT free the slot — the allocation persists. This eliminates the deactivate/reactivate exploit from the previous attempt.

## Implementation Phases

### Phase 1: Billing decision service

Extract a `BillingDecisionService` (or similar) that all creation and reactivation paths call. This service answers:
- `requires_payment?(user, entity_type)` — considering exemptions, quotas, and subscription status
- `apply_free_quota!(user, entity)` — allocates a quota slot if available, sets `billing_exempt` on entity

All controller billing checks delegate to this service.

### Phase 2: PromoCode model and admin CRUD

- `PromoCode` and `PromoCodeRedemption` models with validations
- Admin UI at `/app-admin/promo-codes` — list, create, view redemptions, deactivate
- `PromoQuotaAllocation` model

### Phase 3: Redemption flow

- Promo code input on `/billing` page
- URL parameter `?promo=CODE` support
- `POST /billing/redeem` endpoint
- On redemption: create record, increment count, set `billing_exempt` on user if `free_account`

### Phase 4: Quota application

- Wire `BillingDecisionService` into agent and collective creation flows
- Auto-exempt entities when quota is available
- Skip billing confirmation for free entities
- Show remaining quota on `/billing` page

## Open Questions

1. **Should deactivating a free entity free the quota slot?** The previous implementation said yes, which led to exploits. The revised design says no (allocation persists). But this means a user who creates and then deletes a bad agent loses a slot permanently. Is that acceptable?

2. **Cross-tenant quota scope:** Does a promo code's quota apply globally across all tenants, or per-tenant? The subscription is cross-tenant, so quota should probably be too.

3. **Promo code + existing subscription:** If a non-exempt user with an active subscription redeems a code granting `free_account`, should the subscription be cancelled? Or does it just mean their base quantity drops to 0 (still billed for non-exempt agents)?
