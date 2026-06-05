# User-lists PR review — fixes before merge

Findings from the multi-agent review (security/privacy, code-quality,
test-coverage) + direct MCP exercise of the markdown UI. Listed in the
order to be addressed. Each item: behavior → repro test → fix.

## Must fix

### 1. `create_user_list` action definition omits `add_policy`

**Behavior.** Controller `execute_create_user_list` reads
`params[:add_policy]` and defaults to `"owner_only"`
([app/controllers/user_lists_controller.rb:116](app/controllers/user_lists_controller.rb#L116)),
but the action definition in
[app/services/actions_helper.rb](app/services/actions_helper.rb) only
documents `name`, `description`, `visibility`. Agents reading the
action's `params` list can't discover `add_policy`. They learn it
exists only via the update action.

**Repro.** A test that asserts the action definition for
`create_user_list` includes `add_policy` in its `params` and in its
`params_string`.

**Fix.** Add the param entry + extend `params_string`.

### 2. Always-true guard at `users/show.html.erb:57`

**Behavior.** The expression
`(!@showing_user.collective_identity? || !@showing_user.ai_agent?)`
is always true — a User is exclusively one `user_type`. The outer
guard is dead code. Behavior is correct only because inner
conditionals do the right gating. A reader would assume the guard is
load-bearing.

**Repro.** Read the guard; demonstrate via inspection. (No
behavior-changing test possible since current behavior is correct.)

**Fix.** Change `||` to `&&` so the guard matches its intent (hide
the kebab menu for collective-identity AND ai-agent users), or
remove the redundant outer guard if inner ones cover it.

### 3. `execute_tune_in` / `execute_tune_out` unauthenticated path untested

**Behavior.** Both actions handle `list_action_unauthenticated`
returning 401, but no test exercises the path.

**Repro.** Two new tests in
[test/controllers/users_tune_in_actions_test.rb](test/controllers/users_tune_in_actions_test.rb)
that send the request with no auth and assert 401.

**Fix.** Tests close the gap; no production code change needed unless
the test reveals a bug.

### 4. Home feed cross-tenant isolation untested

**Behavior.** The home feed scopes via `main_collective_scope(tenant)`.
The only barrier preventing cross-tenant leakage is that scope. A
future refactor could regress silently.

**Repro.** New test in
[test/controllers/home_controller_test.rb](test/controllers/home_controller_test.rb):
create a tune-in target who posts in a DIFFERENT tenant's main
collective; assert the post does NOT appear on the viewer's home
feed.

**Fix.** Test closes the gap. If the test fails, that's a real bug
and we fix the scoping.

## Should fix

### 5. N+1 on `/lists/:id` Members tab

**Behavior.**
[app/controllers/user_lists_controller.rb:36-37](app/controllers/user_lists_controller.rb#L36-L37)
loads members without pre-attaching `tenant_user`. View calls
`member.display_name` → one TenantUser query per member row.

**Repro.** Use `assert_queries_count` (or equivalent) in a test that
loads the show page with 5+ members; assert the query count is
constant (not proportional to member count).

**Fix.** Mirror the pattern in `User#mutuals_in`: load TenantUsers
once, attach via `u.tenant_user = tu` on each User instance.

### 6. Duplicated intersection on profile show

**Behavior.**
[app/controllers/users_controller.rb:53-68](app/controllers/users_controller.rb#L53-L68)
computes `@common_collectives` twice (line 54 + again ~line 64).
Each computation triggers two collection loads.

**Repro.** Same `assert_queries_count` pattern on
`GET /u/:handle` for an authenticated viewer.

**Fix.** Cache the intersection once and reuse.

### 7. Four extra queries per profile view for tune-in state

**Behavior.** `compute_target_on_my_list` and
`compute_viewer_on_target_list` each do 1 SELECT for the primary
list + 1 EXISTS for membership = 4 round-trips per profile.

**Repro.** Query-count test on `GET /u/:handle`.

**Fix.** Single combined query (two `UserListMember` rows keyed by
`(owner, user)` pairs in one `WHERE IN`).

### 8. Block-cleanup race window — DROPPED

The review agent flagged a hypothetical race: TX1 inserts a
UserListMember while TX2's cleanup runs before T1 commits, so the
cleanup misses the in-flight row. Vanishingly rare in practice;
no production fix.

The existing artificial test that bypassed `respects_blocks` to
manufacture the post-race state has been removed — it was testing
behavior that doesn't matter for any real user flow. The real
block-cleanup contract under normal conditions is already covered
by `test/models/user_block_test.rb`.

Custom-list cleanup negation test (#12) kept — it's a real contract
worth pinning.

### 9. `tune_in` accepts suspended and `collective_identity` targets

**Behavior.** Search excludes these
([app/services/search_query.rb:137,142](app/services/search_query.rb#L137-L142)),
but the direct `execute_tune_in` endpoint doesn't. Suspended users
remain tune-targets; collective-identity users produce broken
notification URLs (their `path` may be nil).

**Repro.** Two tests:
(a) Try to tune in to a suspended user → 422.
(b) Try to tune in to a collective_identity user → 422.

**Fix.** Add guards in `execute_tune_in` (and `execute_join_list` /
`execute_add_member_to_list` for the same reason). Mirror existing
self-tune-in rejection.

### 10. `primary_user_list_in!` rescue is too broad

**Behavior.**
[app/models/user.rb:59-64](app/models/user.rb#L59-L64) rescues
`RecordInvalid, RecordNotUnique` then re-queries with `T.must(...)`.
If the original failure was anything other than a uniqueness race
(e.g., `tenant.main_collective` is nil), the re-query returns nil
and `T.must(nil)` raises a confusing `TypeError` instead of the
original validation error.

**Repro.** Stub `UserList.create!` to raise a non-uniqueness
`RecordInvalid` (e.g., with `Mocha` / `stub`). Without the fix:
test fails with `TypeError` from `T.must(nil)`. With the fix:
test passes because `RecordInvalid` re-raises.

**Fix.** Narrow rescue to `RecordNotUnique` only (the actual race
indicator); let `RecordInvalid` bubble up.

## Notification spam — separate consideration

### 11. Rapid tune-out / tune-in fires fresh notifications each cycle

**Behavior.** Each `UserListMember.create!` fires a `tune_in`
notification. A user can spam the target by toggling the button.

**Repro.** Test: tune in, tune out, tune in again → assert only one
notification exists OR that subsequent ones reuse / update the
existing undismissed row.

**Fix.** Two options:
(a) Per-target dedupe within a time window (~24h) — mirror the
chat-message dispatcher's pattern: if an undismissed `tune_in`
notification already exists for `(actor, recipient)`, update its
timestamp instead of creating a new row.
(b) Suppress entirely if `target` already received a tune-in
notification from `actor` and never dismissed it.

Lean: (a). Matches existing precedent. Defer to a separate commit
since it's behavior-shaping rather than a bug fix.

## Coverage gaps to close opportunistically

These don't need their own commits — fold into the related fix commit
when convenient:

- **12.** `UserBlock` cleanup does NOT touch custom lists (only
  primary). Add a test in [test/models/user_block_test.rb](test/models/user_block_test.rb)
  to pin this.
- **13.** `describe_add_member_to_list` /
  `describe_remove_member_from_list` / `describe_delete_user_list`
  on a private list the viewer can't see → 404 (existence-hiding).
- **14.** Anonymous viewer hitting `/u/:handle/mutuals` — pin
  whether it 200s, redirects, or 401s.
- **15.** `mutuals.md.erb` rendering — markdown format never tested.
- **16.** `list:tuned_in` when viewer has no primary list yet
  (parser path); `list:` combined with another filter
  (e.g. `list:tuned_in type:note keyword`).
- **17.** `join_list` controller path → dispatcher silence (existing
  test creates the membership directly, not through the controller).
- **18.** Public custom-list add by NON-owner (members_add /
  anyone_add) → notification still fires with adder's name.
- **19.** `tune_in` channel preference defaults (in_app=true,
  email=false).

## Out of scope for this pass

- Cosmetic search results `Collective: [app.harmonic.local]()`
  empty-href rendering.
- `handle = ?` clause redundant with `handle ILIKE ?` in
  search_query.rb.
- `pluck → NOT IN` block exclusion (cheap today, refactor when hot).
- `visible_lists_owned_by` extraction to a shared helper.
- `list.members.size` → `list.user_list_members.size`.
- Stable ordering on Members tab.
- Re-granting the Claude Code Primary agent's capabilities to match
  the renamed actions (dev DB state, documented in shipped plan).

## Execution order

Per-commit TDD: failing test FIRST in each commit, run to see red,
then implement, run to see green. Targeted tests only locally.
Opportunistic coverage items (#12-19) fold into the related
commit when they share files; otherwise skipped.

1. **Action definition + UI dead code** (#1, #2). Tiny, no-blast-radius.
2. **Auth path coverage** (#3). Adds two tests; no production change
   unless they reveal a bug.
3. **Cross-tenant feed isolation coverage** (#4). One test; no
   production change unless it reveals a bug. Folds in #19 (channel
   defaults) since both touch new test infrastructure.
4. **Profile-page hot path: N+1 + dedup** (#5, #6, #7). One commit
   on the same render path.
5. **Block race / mutuals defense in depth** (#8). Folds in #12
   (custom-list cleanup negation test).
6. **Tune-in target validation** (#9). Folds in #17 (`join_list`
   silence integration) since both extend tune-in test coverage.
7. **Narrow rescue in `primary_user_list_in!`** (#10).
8. **Notification dedupe** (#11). Behavior-shaping; may defer.

Coverage items #13-#16, #18 either fold naturally into a related
commit above or skip if they don't fit cleanly. Don't force a
catch-all "tests" commit — adds noise, harder to bisect.
