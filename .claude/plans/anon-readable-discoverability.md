# Discoverability for anon-readable tenants — robots.txt + OG meta

Follow-up to [completed/2026/05/anonymous-read-access-main-collective.md](completed/2026/05/anonymous-read-access-main-collective.md), which shipped anonymous read access to main-collective items, help, and user profiles but deferred crawler/preview surfaces to this separate PR.

## Goal

Make anon-readable content **previewable** (link unfurlers — Slack, iMessage, Twitter/X, Discord, Mastodon, LinkedIn, Bluesky) on tenants in `ANON_READABLE_TENANT_SUBDOMAINS`. Tell crawlers what's anon-allowed via robots.txt. Hard-enforce the inverse on all other tenants: no crawler hint, no preview metadata.

**Sitemap.xml deliberately NOT in scope** — see "Out of scope" below for the rationale. The PR was originally planned with a sitemap; it was dropped on review because Harmonic isn't a search-discoverability product.

## Hard invariant

**Tenants NOT in `ANON_READABLE_TENANT_SUBDOMAINS` (and unknown subdomains):**
- `robots.txt` → `User-agent: *\nDisallow: /\n`
- Every HTML response includes `X-Robots-Tag: noindex, nofollow`
- No OG / Twitter meta tags

**Tenants IN `ANON_READABLE_TENANT_SUBDOMAINS`:**
- `robots.txt` allows the four anon URL shapes and disallows the rest
- Anon-readable show responses omit the noindex header and emit OG/Twitter + canonical
- All other responses (settings, /workspace, auth flow) still get noindex

Enforced by extending [`anonymous_read_access_route_sweep_test.rb`](../../test/integration/anonymous_read_access_route_sweep_test.rb): on a private tenant, each ANON_ALLOWED URL must have `X-Robots-Tag: noindex, nofollow` on its redirect response. A separate test pins the robots.txt content for both tenant types.

## Scope

### OG/Twitter meta surfaces

Same five URL shapes:
- `/n/:id` — title from `@note.title` (fallback below), description from body excerpt
- `/d/:id` — title from `@decision.question`, description from `@decision.description` or excerpt
- `/c/:id` — title from `@commitment.title`, description from `@commitment.description`
- `/u/:handle` — title from `@showing_user.display_name`, description = `"#{display_name} on #{fqdn}"` (no per-user copy in v1; user-type labels were considered and dropped as low-value/jargon)
- `/help/:topic` — title `"Help — #{topic.titleize}"`, description = first paragraph of the help markdown

OG image: single generic Harmonic PNG at `public/og-default.png` (~1200×630, matches the existing favicon-in-`public/` convention). Per-content rendered OG images explicitly deferred.

## Design

### A. robots.txt — `ActionController::Base`, not ApplicationController

The 6-condition anon bypass requires `public_main_collective?` (private tenants couldn't serve robots.txt under it) AND HTML/markdown format (robots is `text/plain`). Both fail. Inheriting from `ApplicationController` would 302 → /login.

Pattern follows existing `MetricsController < ActionController::Base # rubocop:disable Rails/ApplicationController`.

```ruby
# config/routes.rb
get "/robots.txt" => "robots#show", as: :robots, defaults: { format: :txt }
```

```ruby
# app/controllers/robots_controller.rb
class RobotsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  PRIVATE_BODY = "User-agent: *\nDisallow: /\n".freeze

  def show
    tenant = Tenant.find_by(subdomain: request.subdomain)
    expires_in 1.hour, public: false
    response.set_header("X-Robots-Tag", "noindex")  # robots.txt itself shouldn't be indexed
    body = tenant&.public_main_collective? ? PUBLIC_BODY : PRIVATE_BODY
    render plain: body, content_type: "text/plain"
  end

  PUBLIC_BODY = <<~TXT.freeze
    User-agent: *
    Disallow: /

    Allow: /n/
    Allow: /d/
    Allow: /c/
    Allow: /u/
    Allow: /help
    Allow: /help/
  TXT
end
```

`Disallow: /` first with explicit `Allow:` per-path is the form Google and Bing both interpret correctly (longest-match-wins). Unknown subdomain (`tenant.nil?`) falls through to PRIVATE_ROBOTS — safe default.

No `Sitemap:` directive — see "Out of scope" for the rationale.

**`expires_in 1.hour, public: false`** — short browser cache (revalidate hourly), `private` so CDNs don't share across hosts. The previous draft had `set_no_cache_headers` AND `expires_in` which contradicted; only `expires_in` here.

### B. OG / Twitter meta — controller header, view emits HTML

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
@page_title = @note.title.presence || excerpt(@note.text, max: 50) || "Note #{@note.truncated_id}"
@page_description = excerpt(@note.text, max: 200) || "Note page"

# DecisionsController#show — end of action
@page_description = excerpt(@decision.description.presence || @decision.question, max: 200) || "Decide as a group with Harmonic Team"

# CommitmentsController#show — end of action
@page_description = excerpt(@commitment.description.presence || @commitment.title, max: 200) || "Coordinate with your team"

# UsersController#show — end of action
@page_title = @showing_user.display_name
@page_description = "#{@showing_user.display_name} on #{@current_tenant.subdomain}.#{ENV['HOSTNAME']}"

# HelpController#render_help_html — set inside the existing private method
@page_description ||= excerpt(markdown_content, max: 200)
```

`excerpt` is a private method on `ApplicationController`: first non-heading paragraph, whitespace-collapsed, truncated at word boundary with a `…` suffix. No markdown stripping (most markdown reads fine in unfurl previews; a regex stripper is more risk than reward). ~6 lines inline.

### C. Privacy doc update

Add one sentence to the Public Space branch of [`app/views/help/privacy.md.erb`](../../app/views/help/privacy.md.erb), inside the `<% if public_main %>` block:

> Content in this space may be indexed by search engines and shown as link previews when shared.

## Test plan (TDD — failing tests first)

### Phase 1: robots.txt

`test/integration/robots_test.rb`:

- Anon-readable tenant: GET `/robots.txt` → 200, `text/plain`, contains `Allow: /n/`, no `Sitemap:` directive
- Private tenant: GET `/robots.txt` → 200, `text/plain`, body equals `"User-agent: *\nDisallow: /\n"`
- Unknown subdomain (no matching Tenant): GET `/robots.txt` → 200, private-rules body
- HEAD also works (crawler probes)
- Cache-Control includes `max-age=3600` and `private`
- `X-Robots-Tag: noindex` on the response itself (robots.txt shouldn't be indexed)

### Phase 2: OG / Twitter meta + X-Robots-Tag

`test/integration/meta_tags_test.rb`:

- Anon GET `/n/:id` on public tenant → body contains `<meta property="og:title"` with the note title, NO `X-Robots-Tag` header
- Anon GET `/n/:id` on public tenant, with a note that has empty title → `og:title` falls back to excerpt
- Logged-in GET `/n/:id` on public tenant → `X-Robots-Tag: noindex, nofollow` set, OG block ABSENT (per-user chrome shouldn't be indexed)
- Anon GET `/u/:handle` on public tenant → `og:description` matches `"#{display_name} on <host>"`
- Anon GET `/help/privacy` on public tenant → OG block present
- Anon GET `/settings` (a redirect path) — N/A, but: any non-anon-allowed action on a public tenant when logged in still sets noindex
- Anon GET on a PRIVATE tenant for any URL → noindex header (after redirect) — covered by route sweep extension
- OG image URL resolves: `assert image_url('og-default.png').present?` — and the file actually exists at `app/assets/images/og-default.png`

### Phase 3: Extend the route sweep depth check

In [`anonymous_read_access_route_sweep_test.rb`](../../test/integration/anonymous_read_access_route_sweep_test.rb):

- Existing depth-check loop: after asserting 302 → /login on a private tenant, also assert `response.headers["X-Robots-Tag"] == "noindex, nofollow"`
- Add: GET `/robots.txt` on private tenant → 200 with private body

### Phase 4: Manual

`test/manual/anon_discoverability/anon_discoverability.manual_test.md`:

- `curl https://app.harmonic.local/robots.txt` — verify contents
- Paste a `/n/:id` URL into Slack and confirm unfurl shows title/description/image
- Repeat for Twitter Card Validator (cards-dev.twitter.com/validator)
- Repeat for iMessage (paste in message — preview renders inline)
- On a private dev tenant: robots.txt is `Disallow: /`
- View page source on `/n/:id` anon — `og:` tags present, no `noindex`
- View page source same URL logged-in — `X-Robots-Tag` header present, no `og:` tags

## Files

- `public/robots.txt` — **delete** (replaced by RobotsController route)
- `config/routes.rb` — add robots route
- `app/controllers/robots_controller.rb` — new, `< ActionController::Base`
- `app/views/shared/_meta_tags.html.erb` — new (description + conditional OG block)
- `app/views/layouts/application.html.erb` — render `_meta_tags`, drop the existing solo `<meta name="description">`
- `app/controllers/application_controller.rb` — `set_robots_header` before_action + `anon_readable_indexable_response?` helper
- `app/controllers/{notes,decisions,commitments,users}_controller.rb` — set `@page_description` (and `@page_title` for users) at end of show
- `ApplicationController#excerpt(text, max:)` private method — inlined directly on the base controller (was a separate service module; turned out small enough that a dedicated module was overkill)
- `public/og-default.png` — new ~1200×630 PNG (matches existing convention; favicons and `placeholder.png` all live in `public/`, not `app/assets/images/` which is empty)
- `app/views/help/privacy.md.erb` — one-line addition inside `<% if public_main %>` branch
- Tests: `robots_test.rb`, `meta_tags_test.rb`; extend route sweep
- `test/manual/anon_discoverability/anon_discoverability.manual_test.md` — new

## Risks / decisions to verify during implementation

- **Cloudflare/CDN behavior**: `expires_in 1.hour, public: false` should not be cached by Cloudflare across hosts. Verify in staging that two hostnames don't share a cached response.
- **OG image asset path**: served from `public/og-default.png` (sprockets isn't involved; this is a static file). URL is `"#{request.base_url}/og-default.png"` — bare path, no digest, stable forever.
- **Rack::Attack 300/min/IP throttle on crawlers**: Googlebot hits multiple URLs in bursts. Could trip the throttle. Watch for it after launch; consider allowlisting known good crawler IP ranges if observed (Google publishes them).

## Out of scope (explicitly deferred)

- **sitemap.xml** — dropped on review. Harmonic isn't a search-discoverability product; users come via direct links, not Google. Anon-allowed pages also have almost no internal linking that crawlers could follow from a sitemap (the home page is a logged-in directory; profile pages aren't reachable from anywhere without a direct link). If Google indexing of Harmonic content becomes a goal, re-introduce a sitemap then — and do it right: sitemap index for >50K URLs, background generation via Sidekiq job, cached output, no per-request DB build.
- Per-content rendered OG images — single generic image for v1
- Per-user opt-out of indexing — could add `users.noindex_profile` boolean later
- Robots crawl-delay tuning — defaults are fine
- Schema.org / JSON-LD structured data (Article, Person, FAQPage) — nice-to-have v2
- IndexNow / Bing webmaster submission — one-time manual config, not code
- `<link rel="alternate" hreflang>` — single language currently

## Estimated shape

~1 day:
- Done (Phase 1): robots.txt + tests (mechanical)
- Half-day (Phase 2): OG/meta partial + ApplicationController hook + per-controller `@page_description` + ContentExcerpt + tests
- Quarter-day (Phases 3-4): route-sweep extension + manual verification across unfurlers

## Decisions confirmed with the user

1. **Profile pages indexable**: all anon-readable `/u/:handle` (including AI agents, collective identities; excluding archived) get OG tags and no `noindex` (collective-identity verification TBD per the known limitation above).
2. **OG image**: single generic Harmonic PNG, ~1200×630, at `public/og-default.png`. Per-content rendered images deferred.
3. **OG image asset creation**: user provides the designed PNG before implementation begins. Implementation is blocked on the asset.
4. **No sitemap.xml**: dropped on review. See "Out of scope" for rationale.
5. **Inheritance**: RobotsController inherits from `ActionController::Base` (precedent: MetricsController), not ApplicationController. Cleaner separation from the auth pipeline.
6. **Profile OG description**: generic `"#{display_name} on #{fqdn}"`. User-type labels ("Person", "AI Agent", etc.) considered and dropped — "Person" is redundant, "Collective Identity" is jargon. No per-user bio field exists in the schema; adding one is out of scope here.
7. **Both `<meta name="robots">` and `X-Robots-Tag` header**: drop the meta tag, keep only the header (set in controller, not view). One source of truth; works for non-HTML responses too.
