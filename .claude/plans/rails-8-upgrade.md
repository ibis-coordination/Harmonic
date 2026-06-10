# Rails 7.2 → 8.x upgrade

Goal: get off Rails 7.2 before its 2026-08-09 EOL. Spike findings below; effort estimate at the bottom.

## Spike: current state

**Rails:** `7.2.3.1`, `config.load_defaults 7.2`. Gemfile pin: `gem "rails", "~> 7.2"`.

**Deprecation warnings in CI.** Ran the full model + controller test suites and grepped `DEPRECATION WARNING`. Exactly **one** unique warning surfaces:

```
DEPRECATION WARNING: ActiveSupport::ProxyObject is deprecated and will be removed in Rails 8.0.
```

Source: `jbuilder` (2.11.5) — not our code. Resolved by bumping jbuilder to 2.15+ (which moved off `ProxyObject`).

**No app-level deprecations.** We don't call any of the common removed-in-8 APIs:
- `before_filter` / `after_filter` / `around_filter` / `skip_before_filter` — zero hits.
- `.update_attributes` / `.update_attributes!` — zero hits.
- `render :text` (vs. `render plain:`) — zero hits.
- YAML-serialized columns (`serialize :col, ClassName`) — none.
- `alias_method_chain`, `ActionController::Parameters.permit_all_parameters` — none.

**Existing patterns are already modern:**
- Sorbet typed: true on models, strong-params everywhere, Active Record default_scopes for tenancy.
- ViewComponent (4.9), Turbo + Stimulus, jsbundling, sprockets-rails.
- Sidekiq 8.0 (already on the major that 8.x apps run on).

## Gem compatibility

All Rails-coupled gems we use have published versions whose minimum Rails / railties is ≤ 7.1; none pin 7.x specifically.

| Gem                             | Current  | Latest   | Minimum Rails | Notes |
|---------------------------------|----------|----------|---------------|-------|
| `turbo-rails`                   | 1.0.1    | 2.0.23   | actionpack ≥ 7.1 | **Biggest jump.** 1.x → 2.x; see below. |
| `stimulus-rails`                | 1.0.2    | 1.3.4    | railties ≥ 6.0 | Minor. |
| `view_component`                | 4.9.0    | 4.12.0   | actionview ≥ 7.1 | Minor patch / minor. |
| `factory_bot_rails`             | 6.2.0    | 6.5.1    | railties ≥ 6.1 | Minor. |
| `sprockets-rails`               | 3.4.2    | 3.5.2    | actionpack ≥ 6.1 | Patch. |
| `jsbundling-rails`              | 1.3.1    | 1.3.1    | railties ≥ 6.0 | Already current. |
| `sentry-rails`                  | 6.3.0    | 6.6.2    | railties ≥ 5.2 | Minor. |
| `jbuilder`                      | 2.11.5   | 2.15.1   | actionview ≥ 7.0 | Drops the `ActiveSupport::ProxyObject` use. |
| `omniauth-rails_csrf_protection`| 1.0.1    | 1.0.x    | n/a            | Stable. |
| `rubocop-rails`                 | 2.30.3   | 2.30.x   | n/a            | Stable. |
| `yabeda-rails`                  | 0.11.0   | 0.11.x   | n/a            | Stable. |

No gem requires Rails 7.x specifically. No gem is unmaintained / blocking.

## Turbo 1.x → 2.x

Our Turbo footprint is small enough that the upgrade should be uneventful:

- All matches in views are HTML data-attributes (`data-turbo-confirm`, `data-turbo-track`, `data-turbo="false"`). Both behaviors are unchanged in Turbo 2.x.
- No `turbo_frame_tag` / `turbo_stream_from` / `turbo_stream.update` usage.
- No JS-level `Turbo.*` calls in our handwritten controllers.

Known behavior changes in Turbo 2.x worth a smoke test:
- Prefetch on hover is enabled by default — could cause unexpected GET hits in dev observability. (Disable by setting `<meta name="turbo-prefetch" content="false">` if needed.)
- Cache-control + frame caching semantics tightened — watch for any "stale form" reports after deploy.

## `config.load_defaults 8.0` — flags to audit

Flipping the defaults flag activates a batch of behavior changes. The ones with the highest chance of breaking something here:

- **`config.action_controller.allow_deprecated_parameters_hash_equality = false`** — comparing `params` to plain hashes is removed. Need to grep our controllers/tests for direct `params == { ... }` comparisons (low chance of any).
- **`config.action_view.default_form_builder` strict-locals enforcement** — ViewComponent partials with `local_assigns.fetch` patterns should be fine; freshly-rendered partials should be audited.
- **`config.active_record.has_many_inversing = true`** — already default in 7.2.
- **`config.active_record.run_after_transaction_callbacks_in_order_defined = true`** — already default.
- **`config.active_support.executor_around_test_case = true`** — runs the Rails executor around tests. Our tests already use scope_thread_to_tenant patterns; should be fine but watch for stray thread-state leaks.
- **`config.action_dispatch.strict_freshness = true`** — `ETag`/`stale?` semantics tighten; we don't use these.

Nothing here looks load-bearing for our code.

## Migration order

Single PR, narrow scope:

1. Bump `gem "rails", "~> 8.0"`. Run `bundle update rails`.
2. Bump `turbo-rails`, `jbuilder`, `view_component`, `factory_bot_rails`, `sprockets-rails`, `sentry-rails`, `stimulus-rails` to the latest minor.
3. Regenerate Sorbet RBIs (`bundle exec tapioca gem` then `bundle exec tapioca dsl`).
4. Flip `config.load_defaults 7.2` → `8.0` in `config/application.rb`. Read every new initializer Rails generates in `config/initializers/new_framework_defaults_8_0.rb` and inline-merge the ones we want, drop the rest.
5. Run the full test suite. Expected work:
   - Some tapioca-regenerated RBIs may shift signatures — Sorbet errors to chase down (mechanical).
   - Possible Turbo 2.x prefetch surprises in any tests that count GET hits.
6. Smoke-test in development: the dual HTML/markdown views on `/u/:handle`, the cropper modal, the lightbox, the AJAX toggle button. Anything Turbo-touching.
7. Update `config/brakeman.ignore` to remove the EOLRails entry.
8. CHANGELOG entry (post-merge per the repo convention).

## Effort estimate

**Small.** Maybe a half day to a day of focused work, dominated by:
- The Turbo 1 → 2 smoke pass (highest risk area, low chance of issues given our minimal usage).
- The `load_defaults 8.0` flag audit (mostly reading the new defaults file and confirming each flag).
- Sorbet RBI regeneration and chasing any signature shifts.

No app-level rewrites. No data migrations. No deprecated APIs to retire. The fact that we run zero app-originated deprecation warnings under Rails 7.2 means we built on patterns that survive the 8.x bump unchanged.

## Open questions

1. **Skip 8.0 and go to 8.1 / latest?** Rails 8.1 is out; might as well land on the newest patch.
2. **Want to roll the e2e Playwright suite too** as part of the smoke pass, or trust the integration tests?
3. **Are there any production-only configs not exercised in dev/test** (Redis cache, S3 active_storage variants) we should manually verify after the upgrade?
