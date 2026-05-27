# Discoverability for anon-readable tenants — robots.txt + sitemap.xml + OG meta

Follow-up to [completed/2026/05/anonymous-read-access-main-collective.md](completed/2026/05/anonymous-read-access-main-collective.md), which shipped anonymous read access to main-collective items, help, and user profiles but deferred crawler/preview surfaces to this separate PR.

## Goal

Make anon-readable content **findable** (search engines) and **previewable** (link unfurlers — Slack, iMessage, Twitter/X, Discord, Mastodon, LinkedIn, Bluesky) on tenants in `ANON_READABLE_TENANT_SUBDOMAINS`. Hard-enforce the inverse on all other tenants: no crawler hint, no sitemap entry, no preview metadata.

## Hard invariant

**Tenants NOT in `ANON_READABLE_TENANT_SUBDOMAINS` (and unknown subdomains):**
- `robots.txt` → `User-agent: *\nDisallow: /\n`
- `sitemap.xml` → 404
- Every HTML response includes `X-Robots-Tag: noindex, nofollow`
- No OG / Twitter meta tags

**Tenants IN `ANON_READABLE_TENANT_SUBDOMAINS`:**
- `robots.txt` allows the four anon URL shapes and disallows the rest, with a `Sitemap:` line
- `sitemap.xml` lists anon-readable URLs (paginated only when count requires it)
- Anon-readable show responses omit the noindex header and emit OG/Twitter + canonical
- All other responses (settings, /workspace, auth flow) still get noindex

Enforced by extending [`anonymous_read_access_route_sweep_test.rb`](../../test/integration/anonymous_read_access_route_sweep_test.rb): on a private tenant, each ANON_ALLOWED URL must have `X-Robots-Tag: noindex, nofollow` on its redirect response, AND `/sitemap.xml` must 404. A separate test pins the robots.txt content for both tenant types.

## Scope

### In sitemap (on anon-readable tenants)

- `/` (home page — context)
- `/help` + every available `/help/:topic`
- `/n/<truncated_id>` for every not-deleted note in the main collective
- `/d/<truncated_id>` for every not-deleted decision in the main collective
- `/c/<truncated_id>` for every not-deleted commitment in the main collective
- `/u/<handle>` for every user with a non-archived tenant_user (per the existing `User#archived?` semantics — archived lives on `tenant_users.archived_at`)

URL construction uses `item.path` (already returns the bare `/<prefix>/<truncated_id>` for main-collective items — `Collective#path` is nil for the main collective and the `ApplicationRecord#path` interpolation handles nil cleanly). Sitemap entries prepend the canonical base URL built from `ENV['HOSTNAME']` + `tenant.subdomain` (matching the existing webhook URL pattern in [collective_automations/show.md.erb:19-20](../../app/views/collective_automations/show.md.erb#L19-L20)) — NOT `request.host_with_port`, which can carry an internal upstream port when behind a reverse proxy/CDN.

### NOT in sitemap

- Anything in a non-main collective (members-only)
- Soft-deleted items (use `SoftDeletable.not_deleted` scope — matches existing codebase pattern)
- `/login`, `/signup`, `/activate`, password-reset, `/workspace`, settings, any write endpoint
- API/JSON URLs

### OG/Twitter meta surfaces

Same five URL shapes:
- `/n/:id` — title from `@note.title` (fallback below), description from body excerpt
- `/d/:id` — title from `@decision.question`, description from `@decision.description` or excerpt
- `/c/:id` — title from `@commitment.title`, description from `@commitment.description`
- `/u/:handle` — title from `@showing_user.display_name`, description = generic `"#{display_name} — #{user_type_label} on #{fqdn}"` (no `bio` field exists; per-user OG copy is out of v1 scope)
- `/help/:topic` — title `"Help — #{topic.titleize}"`, description = first paragraph of the help markdown

OG image: single generic Harmonic PNG at `public/og-default.png` (~1200×630, matches the existing favicon-in-`public/` convention). Per-content rendered OG images explicitly deferred.

## Design

### A. robots.txt — `ActionController::Base`, not ApplicationController

The 6-condition anon bypass requires `public_main_collective?` (private tenants couldn't serve robots.txt under it) AND HTML/markdown format (robots is `text/plain`, sitemap is `application/xml`). Both fail. Inheriting from `ApplicationController` would 302 → /login.

Pattern follows existing `MetricsController < ActionController::Base # rubocop:disable Rails/ApplicationController`.

```ruby
# config/routes.rb
get "/robots.txt" => "robots#show", as: :robots, defaults: { format: :txt }
get "/sitemap.xml" => "sitemaps#show", as: :sitemap, defaults: { format: :xml }
```

```ruby
# app/controllers/robots_controller.rb
class RobotsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  def show
    tenant = Tenant.find_by(subdomain: request.subdomain)
    expires_in 1.hour, public: false
    response.set_header("X-Robots-Tag", "noindex")  # robots.txt itself shouldn't be indexed

    if tenant&.public_main_collective?
      sitemap_url = "#{request.protocol}#{request.host_with_port}/sitemap.xml"
      render plain: public_robots(sitemap_url), content_type: "text/plain"
    else
      render plain: PRIVATE_ROBOTS, content_type: "text/plain"
    end
  end

  private

  PRIVATE_ROBOTS = "User-agent: *\nDisallow: /\n".freeze

  def public_robots(sitemap_url)
    <<~TXT
      User-agent: *
      Disallow: /

      Allow: /n/
      Allow: /d/
      Allow: /c/
      Allow: /u/
      Allow: /help
      Allow: /help/

      Sitemap: #{sitemap_url}
    TXT
  end
end
```

`Disallow: /` first with explicit `Allow:` per-path is the form Google and Bing both interpret correctly (longest-match-wins). Unknown subdomain (`tenant.nil?`) falls through to PRIVATE_ROBOTS — safe default.

**`expires_in 1.hour, public: false`** — short browser cache (revalidate hourly), `private` so CDNs don't share across hosts. The previous draft had `set_no_cache_headers` AND `expires_in` which contradicted; only `expires_in` here.

### B. sitemap.xml — same inheritance + named scopes

```ruby
# app/controllers/sitemaps_controller.rb
class SitemapsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  SOFT_LIMIT_WARN = 40_000  # warn well before the 50,000-URL protocol limit

  def show
    tenant = Tenant.find_by(subdomain: request.subdomain)
    return head :not_found unless tenant&.public_main_collective?

    @base_url = canonical_base_url_for(tenant)
    @entries = build_entries(tenant)
    Rails.logger.warn("[sitemap] count=#{@entries.size} exceeds soft limit; consider sitemap index") if @entries.size > SOFT_LIMIT_WARN

    expires_in 1.hour, public: false
    response.set_header("X-Robots-Tag", "noindex")
    render formats: :xml
  end

  private

  def canonical_base_url_for(tenant)
    protocol = ENV["HOSTNAME"].to_s.include?("localhost") ? "http" : "https"
    "#{protocol}://#{tenant.subdomain}.#{ENV.fetch('HOSTNAME', nil)}"
  end

  def build_entries(tenant)
    main = tenant.main_collective
    return [] if main.nil?

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.set_thread_context(main)

    entries = []
    entries << { loc: "/", changefreq: "daily", priority: 0.7 }
    entries << { loc: "/help", changefreq: "monthly", priority: 0.5 }
    HelpController::TOPICS.each do |t|
      next unless HelpController.topic_available_for_tenant?(t, tenant)
      entries << { loc: "/help/#{t.to_s.tr('_', '-')}", changefreq: "monthly", priority: 0.4 }
    end
    main.notes.not_deleted.find_each       { |n| entries << { loc: n.path, lastmod: n.updated_at, changefreq: "weekly", priority: 0.6 } }
    main.decisions.not_deleted.find_each   { |d| entries << { loc: d.path, lastmod: d.updated_at, changefreq: "weekly", priority: 0.6 } }
    main.commitments.not_deleted.find_each { |c| entries << { loc: c.path, lastmod: c.updated_at, changefreq: "weekly", priority: 0.6 } }

    # Profiles: archived_at lives on TenantUser, not User. Join.
    tenant.tenant_users.where(archived_at: nil).includes(:user).find_each do |tu|
      entries << { loc: tu.user.path, lastmod: tu.user.updated_at, changefreq: "weekly", priority: 0.5 }
    end

    entries
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end
end
```

```erb
<!-- app/views/sitemaps/show.xml.erb -->
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<% @entries.each do |e| %>
  <url>
    <loc><%= @base_url %><%= e[:loc] %></loc>
    <% if e[:lastmod] %><lastmod><%= e[:lastmod].iso8601 %></lastmod><% end %>
    <% if e[:changefreq] %><changefreq><%= e[:changefreq] %></changefreq><% end %>
    <% if e[:priority] %><priority><%= e[:priority] %></priority><% end %>
  </url>
<% end %>
</urlset>
```

Thread-scope set explicitly so the default-scoped queries on `main.notes` etc. don't pick up whatever happened to be thread-local. `Tenant.scope_thread_to_tenant` and `Collective.set_thread_context` are the existing helpers used elsewhere in the codebase (e.g. test fixtures).

`User#path` returns `/u/:handle` ([app/models/user.rb:381](../../app/models/user.rb#L381)), used by many existing views — no override needed.

### C. HelpController refactor (prerequisite)

`HelpController#help_topic_available?` is currently an instance method that reads `current_tenant` from the controller. The sitemap can't call it. Refactor:

```ruby
# app/controllers/help_controller.rb
def self.topic_available_for_tenant?(topic, tenant)
  flag = FEATURE_GATED_TOPICS[topic.to_s]
  return true if flag.nil?
  tenant.feature_enabled?(flag)
end

# Keep the instance method as a thin delegator so existing call sites work:
def help_topic_available?(topic)
  self.class.topic_available_for_tenant?(topic, current_tenant)
end
```

No behavior change for existing callers. Sitemap calls the class method.

### D. OG / Twitter meta — controller header, view emits HTML

Centralize the noindex decision in a single `ApplicationController` before_action. The view partial only emits OG HTML tags; it does NOT touch response headers (footgun, and redundant).

```ruby
# ApplicationController
before_action :set_robots_header

private

def set_robots_header
  return if anon_readable_indexable_response?
  response.set_header("X-Robots-Tag", "noindex, nofollow")
end

# True only for: anon viewer + public main collective + allows_anonymous action + HTML response.
# Logged-in viewers and markdown responses are intentionally noindex: the
# rendered chrome / per-user content differs from what we want crawlers to see.
def anon_readable_indexable_response?
  @current_user.nil? &&
    @current_tenant&.public_main_collective? &&
    self.class.respond_to?(:allows_anonymous?) &&
    self.class.allows_anonymous?(action_name.to_sym) &&
    request.format.html?
end
helper_method :anon_readable_indexable_response?
```

```erb
<!-- app/views/shared/_meta_tags.html.erb -->
<meta name="description" content="<%= (@page_description || @current_app_description).to_s.truncate(200) %>">

<% if anon_readable_indexable_response? %>
  <% canonical = @canonical_url || request.original_url %>
  <% og_title = (@page_title || @current_app_title).to_s.truncate(70) %>
  <% og_desc = (@page_description || @current_app_description).to_s.truncate(200) %>
  <% og_image = "#{request.base_url}/og-default.png" %>
  <meta property="og:type" content="<%= @page_og_type || "article" %>">
  <meta property="og:title" content="<%= og_title %>">
  <meta property="og:description" content="<%= og_desc %>">
  <meta property="og:image" content="<%= og_image %>">
  <meta property="og:url" content="<%= canonical %>">
  <meta property="og:site_name" content="<%= @current_app_title %>">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="<%= og_title %>">
  <meta name="twitter:description" content="<%= og_desc %>">
  <meta name="twitter:image" content="<%= og_image %>">
  <link rel="canonical" href="<%= canonical %>">
<% end %>
```

Replace the existing solo `<meta name="description">` in [`app/views/layouts/application.html.erb`](../../app/views/layouts/application.html.erb#L10) with `<%= render "shared/meta_tags" %>`. The description meta tag still ships on every page (it's already universal); the OG block is conditional.

Per-action description ivars (small additions):

```ruby
# NotesController#show — end of action
@page_title = @note.title.presence || excerpt_title(@note.body) || "Note"
@page_description = ContentExcerpt.first_paragraph(@note.body, max: 200) if @note.body.present?

# DecisionsController#show — end of action
@page_description = ContentExcerpt.first_paragraph(@decision.description.presence || @decision.question, max: 200)

# CommitmentsController#show — end of action
@page_description = ContentExcerpt.first_paragraph(@commitment.description.presence || @commitment.title, max: 200)

# UsersController#show — end of action
@page_title = @showing_user.display_name
@page_description = "#{@showing_user.display_name} — #{user_type_label(@showing_user)} on #{request.host_with_port}"

# HelpController per-topic — end of action
@page_description = ContentExcerpt.first_paragraph(markdown_content, max: 200)
```

Helpers:

- `ContentExcerpt.first_paragraph(text, max:)` — strip markdown (links → text, headings → text, code fences out), take everything up to first blank line, truncate at word boundary, append `…`. ~10 lines; lives in `app/helpers/markdown_helper.rb` or a small module.
- `excerpt_title(text)` — first ~50 chars at a word boundary, used only when a note has no title.
- `user_type_label(user)` — maps `human` → "Person", `ai_agent` → "AI Agent", `collective_identity` → "Collective Identity".

### E. Privacy doc update

Add one sentence to the Public Space branch of [`app/views/help/privacy.md.erb`](../../app/views/help/privacy.md.erb), inside the `<% if public_main %>` block:

> Content in this space may be indexed by search engines and shown as link previews when shared.

## Test plan (TDD — failing tests first)

### Phase 1: robots.txt

`test/integration/robots_test.rb`:

- Anon-readable tenant: GET `/robots.txt` → 200, `text/plain`, contains `Allow: /n/`, contains `Sitemap: https://<host>/sitemap.xml`
- Private tenant: GET `/robots.txt` → 200, `text/plain`, body equals `"User-agent: *\nDisallow: /\n"`
- Unknown subdomain (no matching Tenant): GET `/robots.txt` → 200, private-rules body
- HEAD also works (crawler probes)
- Cache-Control includes `max-age=3600` and `private`
- `X-Robots-Tag: noindex` on the response itself (robots.txt shouldn't be indexed)

### Phase 2: sitemap.xml

`test/integration/sitemap_test.rb`:

- Anon-readable tenant: GET `/sitemap.xml` → 200, `application/xml`, well-formed (parse with Nokogiri), contains the URL of a fixture note/decision/commitment/user/help-topic with absolute https URL
- Private tenant: GET `/sitemap.xml` → 404
- Unknown subdomain: GET `/sitemap.xml` → 404
- Soft-deleted items: created, soft-deleted, then asserted absent from response
- Archived users (via `tenant_user.archived_at`): created, archived, then asserted absent
- Items in a non-main collective: created, then asserted absent
- Feature-gated help topic with flag off: absent
- `lastmod` field on each item entry matches `item.updated_at.iso8601`
- Count under SOFT_LIMIT_WARN with fixture set; log assertion when artificially over

### Phase 3: OG / Twitter meta + X-Robots-Tag

`test/integration/meta_tags_test.rb`:

- Anon GET `/n/:id` on public tenant → body contains `<meta property="og:title"` with the note title, NO `X-Robots-Tag` header
- Anon GET `/n/:id` on public tenant, with a note that has empty title → `og:title` falls back to excerpt
- Logged-in GET `/n/:id` on public tenant → `X-Robots-Tag: noindex, nofollow` set, OG block ABSENT (per-user chrome shouldn't be indexed)
- Anon GET `/u/:handle` on public tenant → `og:description` matches `"#{display_name} — Person on <host>"` for a human, `"… — AI Agent on …"` for an ai_agent
- Anon GET `/help/privacy` on public tenant → OG block present
- Anon GET `/settings` (a redirect path) — N/A, but: any non-anon-allowed action on a public tenant when logged in still sets noindex
- Anon GET on a PRIVATE tenant for any URL → noindex header (after redirect) — covered by route sweep extension
- OG image URL resolves: `assert image_url('og-default.png').present?` — and the file actually exists at `app/assets/images/og-default.png`

### Phase 4: Extend the route sweep depth check

In [`anonymous_read_access_route_sweep_test.rb`](../../test/integration/anonymous_read_access_route_sweep_test.rb):

- Existing depth-check loop: after asserting 302 → /login on a private tenant, also assert `response.headers["X-Robots-Tag"] == "noindex, nofollow"`
- Add: GET `/sitemap.xml` on private tenant → 404
- Add: GET `/robots.txt` on private tenant → 200 with private body

### Phase 5: Manual

`test/manual/anon_discoverability/anon_discoverability.manual_test.md`:

- `curl https://app.harmonic.local/robots.txt` — verify contents
- `xmllint --noout https://app.harmonic.local/sitemap.xml` — well-formed
- Paste a `/n/:id` URL into Slack and confirm unfurl shows title/description/image
- Repeat for Twitter Card Validator (cards-dev.twitter.com/validator)
- Repeat for iMessage (paste in message — preview renders inline)
- On a private dev tenant: robots.txt is `Disallow: /`, sitemap 404s
- View page source on `/n/:id` anon — `og:` tags present, no `noindex`
- View page source same URL logged-in — `X-Robots-Tag` header present, no `og:` tags

## Files

- `public/robots.txt` — **delete** (replaced by RobotsController route)
- `config/routes.rb` — add robots + sitemap routes
- `app/controllers/robots_controller.rb` — new, `< ActionController::Base`
- `app/controllers/sitemaps_controller.rb` — new, `< ActionController::Base`
- `app/views/sitemaps/show.xml.erb` — new
- `app/views/shared/_meta_tags.html.erb` — new (description + conditional OG block)
- `app/views/layouts/application.html.erb` — render `_meta_tags`, drop the existing solo `<meta name="description">`
- `app/controllers/application_controller.rb` — `set_robots_header` before_action + `anon_readable_indexable_response?` helper
- `app/controllers/help_controller.rb` — add `self.topic_available_for_tenant?` class method; instance method becomes a delegator
- `app/controllers/{notes,decisions,commitments,users}_controller.rb` — set `@page_description` (and `@page_title` for users) at end of show
- `app/helpers/markdown_helper.rb` (or new module) — `ContentExcerpt.first_paragraph`, `excerpt_title`, `user_type_label`
- `public/og-default.png` — new ~1200×630 PNG (matches existing convention; favicons and `placeholder.png` all live in `public/`, not `app/assets/images/` which is empty)
- `app/views/help/privacy.md.erb` — one-line addition inside `<% if public_main %>` branch
- Tests: `robots_test.rb`, `sitemap_test.rb`, `meta_tags_test.rb`; extend route sweep
- `test/manual/anon_discoverability/anon_discoverability.manual_test.md` — new

## Risks / decisions to verify during implementation

- **Thread-scope leak**: the sitemap controller sets `Tenant.scope_thread_to_tenant` to query main collective items. `ensure` block clears it. The route sweep depth check would catch a leak if it happened.
- **Cloudflare/CDN behavior**: `expires_in 1.hour, public: false` should not be cached by Cloudflare across hosts. Verify in staging that two hostnames don't share a cached response.
- **OG image asset path**: served from `public/og-default.png` (sprockets isn't involved; this is a static file). URL is `"#{request.base_url}/og-default.png"` — bare path, no digest, stable forever.
- **Rack::Attack 300/min/IP throttle on crawlers**: Googlebot hits multiple URLs in bursts. Could trip the throttle. Watch for it after launch; consider allowlisting known good crawler IP ranges if observed (Google publishes them).
- **Soft-delete via default_scope?**: SoftDeletable adds a `not_deleted` scope but does NOT add a default_scope. Confirmed — `main.notes` returns ALL including deleted. Sitemap must use `.not_deleted` explicitly. Tests for soft-delete absence are load-bearing.

## Out of scope (explicitly deferred)

- Sitemap index (sitemap-of-sitemaps) for >50K URLs — log warning at 40K; switch when needed
- Per-content rendered OG images — single generic image for v1
- Per-user opt-out of indexing — could add `users.noindex_profile` boolean later
- Robots crawl-delay tuning — defaults are fine
- Schema.org / JSON-LD structured data (Article, Person, FAQPage) — nice-to-have v2
- IndexNow / Bing webmaster submission — one-time manual config, not code
- `<link rel="alternate" hreflang>` — single language currently

## Estimated shape

~1–1.5 days:
- Half-day: robots.txt + sitemap.xml + tests (mechanical, mostly new files)
- Half-day: OG/meta partial + ApplicationController hook + per-controller `@page_description` + ContentExcerpt + tests
- Quarter-day: HelpController class-method refactor (small but cross-cutting)
- Quarter-day: route-sweep extension, OG image asset, privacy doc edit, manual verification across unfurlers

## Decisions confirmed with the user

1. **Profile pages indexed**: all anon-readable `/u/:handle` (including AI agents, collective identities; excluding archived) appear in the sitemap with no `noindex`.
2. **OG image**: single generic Harmonic PNG, ~1200×630, at `public/og-default.png`. Per-content rendered images deferred.
3. **OG image asset creation**: user provides the designed PNG before implementation begins. Implementation is blocked on the asset.
4. **Inheritance**: RobotsController and SitemapsController inherit from `ActionController::Base` (precedent: MetricsController), not ApplicationController. Cleaner separation from the auth pipeline; they truly are meta-files.
5. **Profile OG description**: generic `"#{display_name} — #{user_type_label} on #{fqdn}"`. No per-user bio field exists in the schema; adding one is out of scope here.
6. **Both `<meta name="robots">` and `X-Robots-Tag` header**: drop the meta tag, keep only the header (set in controller, not view). One source of truth; works for non-HTML responses too.
