require "test_helper"

# Route-introspection sweep. Iterates every GET route in
# Rails.application.routes and exercises it as an anon viewer on both a
# public-readable tenant and a private tenant. Any 2xx response that
# isn't covered by the ANON_ALLOWED whitelist is a leak.
#
# This is the LOAD-BEARING safety net for the feature. If a future
# controller change accidentally exposes an action to anon (e.g., wrong
# before_action skip, a new `allows_anonymous` declaration without an
# ANON_ALLOWED entry), this test fails with the offending route(s).
#
# Adding a new anon-allowed route requires three things, all visible in
# code review:
#   1. `allows_anonymous` in the controller
#   2. Entry in ANON_ALLOWED below
#   3. A justification in the PR description
#
# Synthetic param values (`"00000000"`) mean we don't need fixture setup
# beyond the tenants — most allowlisted controllers will 404 on missing
# resources, which counts as "denied" (non-2xx). The positive 2xx case
# is exercised for help routes (no param required) and any allowlisted
# controller that doesn't require a real resource.
class AnonymousReadAccessRouteSweepTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "anonsweeppublic".freeze
  PRIVATE_SUBDOMAIN = "anonsweepprivate".freeze

  # The ground-truth allowlist for the bypass system. Any `(controller,
  # action)` pair NOT in this table that responds 2xx to anon GET via the
  # bypass is a leak. (Auth-flow controllers and a few error pages are
  # legitimately anon-reachable too — handled by additional skip rules in
  # the sweep itself.)
  ANON_ALLOWED = {
    "notes" => [:show].freeze,
    "decisions" => [:show].freeze,
    "commitments" => [:show].freeze,
    "users" => [:show].freeze,
    "help" => ([:index] + HelpController::TOPICS.map(&:to_sym)).freeze,
  }.freeze

  # Pages legitimately public outside the bypass system. Most are pre-login
  # informational pages (404, logout confirmation, etc.) — they were public
  # before this feature existed and remain so.
  OTHER_ANON_REACHABLE = {
    "home" => [:page_not_found].freeze,
  }.freeze

  # Status codes that count as a "legitimate denial" for anon GET:
  # 302 — redirect (e.g., to /login)
  # 401 — unauthorized (API routes without a token)
  # 403 — forbidden (capability checks)
  # 404 — resource not found OR route doesn't match synthetic param
  # 405 — method not allowed (rare on GET; surfaces if a route's GET path
  #       reaches a controller that only handles other verbs)
  # 410 — gone (deleted resources)
  # Anything else — 2xx (leak), 5xx (crash), or unusual 4xx — fails the
  # test rather than silently passing. A 500 is NOT a denial; it means the
  # action crashed and the leak it would have produced is hidden behind
  # the crash.
  DENIAL_STATUSES = [302, 401, 403, 404, 405, 410].freeze

  # Controllers whose routes are skipped by the sweep:
  # - rails/* — Rails internals (mailer previews)
  # - active_storage/* — direct upload / blob serving (own auth model)
  # - view_components, lookbook* — dev-only component preview
  # If a future mounted engine appears, add it explicitly here.
  SKIPPED_CONTROLLER_PREFIXES = %w[rails/ active_storage/ view_components lookbook].freeze
  # Path prefixes to skip in addition to controller-name filtering — catches
  # routes mounted under /rails/ whose controller name doesn't carry the
  # `rails/` prefix (e.g., the view_components preview).
  SKIPPED_PATH_PREFIXES = %w[/rails/].freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!

    @public_tenant = Tenant.create!(subdomain: PUBLIC_SUBDOMAIN, name: "Public")
    @public_user = User.create!(email: "sweepub@example.com", name: "Public", user_type: "human")
    @public_tenant.add_user!(@public_user)
    @public_tenant.create_main_collective!(created_by: @public_user)

    @private_tenant = Tenant.create!(subdomain: PRIVATE_SUBDOMAIN, name: "Private")
    @private_user = User.create!(email: "sweepriv@example.com", name: "Private", user_type: "human")
    @private_tenant.add_user!(@private_user)
    @private_tenant.create_main_collective!(created_by: @private_user)

    # Real fixtures on the private tenant — needed for the
    # "allowlisted URLs with REAL IDs return 302" test below. Without real
    # IDs, the broad sweep can't distinguish "bypass correctly denied" from
    # "bypass fired but resource not found (404)". With real IDs, a broken
    # bypass would return 200 instead of 302 and the test would catch it.
    Tenant.scope_thread_to_tenant(subdomain: PRIVATE_SUBDOMAIN)
    Collective.set_thread_context(@private_tenant.main_collective)
    @private_note = create_note(tenant: @private_tenant, collective: @private_tenant.main_collective, created_by: @private_user)
    @private_decision = create_decision(tenant: @private_tenant, collective: @private_tenant.main_collective, created_by: @private_user)
    @private_commitment = create_commitment(tenant: @private_tenant, collective: @private_tenant.main_collective, created_by: @private_user)
    @private_user_handle = @private_tenant.tenant_users.find_by(user: @private_user).handle
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def teardown
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  # ---- The sweep ----

  test "every anon GET returns a known-denial status or matches the ANON_ALLOWED whitelist (public tenant)" do
    leaks, unexpected = sweep(PUBLIC_SUBDOMAIN)
    assert_empty leaks, <<~MSG
      Anon GET returned 2xx on PUBLIC tenant for routes NOT in ANON_ALLOWED.
      Each leak is either a real bug (forgotten gate) or a new allowlist
      entry needs to be added to this test:

      #{leaks.join("\n")}
    MSG
    assert_empty unexpected, <<~MSG
      Anon GET returned an unexpected status (not 2xx, not a known denial
      status #{DENIAL_STATUSES.inspect}). Likely a controller crashed (5xx)
      — investigate before treating these as denied. A 500 hides the leak
      it would have produced:

      #{unexpected.join("\n")}
    MSG
  end

  test "every anon GET returns a known-denial status on a private tenant (none in allowlist)" do
    # On a private tenant the bypass never fires, so the entire surface
    # must respond with a denial status. Any 2xx is a leak. Any other
    # status (5xx, weird 4xx) is unexpected.
    leaks, unexpected = sweep(PRIVATE_SUBDOMAIN, allowlist: {})
    assert_empty leaks, <<~MSG
      Anon GET returned 2xx on PRIVATE tenant — private tenants must have
      zero anon visibility on any URL:

      #{leaks.join("\n")}
    MSG
    assert_empty unexpected, <<~MSG
      Anon GET returned an unexpected status on PRIVATE tenant. Crashes
      (5xx) mask leaks they might be hiding — investigate:

      #{unexpected.join("\n")}
    MSG
  end

  # This test is the depth-check pairing for the sweep above. The sweep
  # uses synthetic IDs like "00000000", so for the five allowlisted
  # (controller, action) pairs the action always 404s — meaning the sweep
  # CAN'T distinguish "bypass correctly denied" from "bypass fired but
  # resource missing". This test uses REAL fixtures so a broken
  # @current_tenant.public_main_collective? check (or any other regression
  # that would let the bypass fire for private tenants) returns 200 here
  # and fails the test. We assert the response is specifically a redirect
  # to /login (302) — not just any non-2xx — so a crash doesn't pass the
  # test by accident.
  test "every ANON_ALLOWED URL with a REAL resource ID redirects to /login on a PRIVATE tenant" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"

    urls = [
      @private_note.path,
      @private_decision.path,
      @private_commitment.path,
      "/u/#{@private_user_handle}",
      "/help",
      # URLs dasherize the topic (e.g., "reminder-notes"); the action name
      # uses underscores ("reminder_notes" in HelpController::TOPICS).
    ] + HelpController::TOPICS.map { |t| "/help/#{t.tr("_", "-")}" }

    failures = urls.filter_map do |url|
      get url, env: { "REMOTE_ADDR" => fresh_ip }
      next nil if response.status == 302 && response.location&.match?(%r{/login})
      "  GET #{url} → #{response.status} (location=#{response.location.inspect}) — expected 302 to /login"
    end

    assert_empty failures, <<~MSG
      A real ANON_ALLOWED URL did NOT redirect to /login on a PRIVATE
      tenant. A 2xx means the bypass mechanism is firing for tenants
      NOT in ANON_READABLE_TENANT_SUBDOMAINS — the hard invariant of
      this feature is broken. A 5xx or unexpected status means a crash
      is masking what the request would otherwise do. Either way:
      inspect Tenant#public_main_collective? and
      ApplicationController#anonymous_main_collective_read_allowed?:

      #{failures.join("\n")}
    MSG
  end

  # ---- Edge cases (separate test methods, smaller blast radius) ----

  test "allowlisted item URL with collective_handle pointing at a non-main collective redirects to login" do
    other = Collective.create!(tenant: @public_tenant, created_by: @public_user, name: "Other", handle: "anon-sweep-other")
    other.add_user!(@public_user)
    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(other)
    note = create_note(tenant: @public_tenant, collective: other, created_by: @public_user)
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get note.path, env: { "REMOTE_ADDR" => fresh_ip }
    assert_redirected_to %r{/login}
  end

  test "cross-tenant ID guessing returns 302/404, never the other tenant's content" do
    # Create a note in PRIVATE tenant, try to read it from PUBLIC tenant URL
    Tenant.scope_thread_to_tenant(subdomain: PRIVATE_SUBDOMAIN)
    Collective.set_thread_context(@private_tenant.main_collective)
    secret_note = create_note(tenant: @private_tenant, collective: @private_tenant.main_collective,
                              created_by: @private_user, title: "PRIVATE SECRET CONTENT")
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/n/#{secret_note.truncated_id}", env: { "REMOTE_ADDR" => fresh_ip }
    # Should NOT find — the note belongs to a different tenant, tenant-scoped
    # default_scope filters it out.
    assert_includes [302, 404], response.status,
                    "cross-tenant ID lookup leaked content (status #{response.status})"
    assert_no_match(/PRIVATE SECRET CONTENT/, response.body)
  end

  test "anon GET on a request without a known subdomain does NOT return 2xx" do
    # An unknown subdomain shouldn't suddenly become anon-readable. The app
    # raises "Invalid subdomain" in current_collective, which Rails turns into
    # a 500 — both the raise and any non-2xx response satisfy the invariant
    # (no anon content is served for an unknown tenant).
    host! "no-such-subdomain.#{ENV.fetch("HOSTNAME", nil)}"
    begin
      get "/help", env: { "REMOTE_ADDR" => fresh_ip }
    rescue RuntimeError => e
      assert_match(/invalid subdomain/i, e.message)
      return
    end
    assert response.status >= 300, "unknown subdomain returned 2xx (#{response.status})"
  end

  test "AUTH_SUBDOMAIN listed in ANON_READABLE_TENANT_SUBDOMAINS still does NOT expose anon reads" do
    # Misconfiguration check: if an operator includes the auth subdomain in
    # the anon-readable list, anon reads must still be denied because the
    # auth subdomain has no real main collective (it's synthesized).
    auth_sub = ENV.fetch("AUTH_SUBDOMAIN", "auth")
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "#{PUBLIC_SUBDOMAIN},#{auth_sub}"
    Tenant.reset_anon_readable_subdomains!

    host! "#{auth_sub}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help", env: { "REMOTE_ADDR" => fresh_ip }
    # Either redirected (auth subdomain redirects everything non-auth) or
    # 404 (no main collective). Must NOT be 200.
    assert response.status >= 300, "AUTH_SUBDOMAIN should not expose anon reads even when misconfigured into the env var (got #{response.status})"
  end

  private

  def fresh_ip
    "10.#{SecureRandom.random_number(256)}.#{SecureRandom.random_number(256)}.#{SecureRandom.random_number(254) + 1}"
  end

  # Iterate routes and classify each response. Returns [leaks, unexpected]:
  #   leaks      — 2xx responses for (controller, action) NOT in allowlist
  #   unexpected — non-2xx statuses outside DENIAL_STATUSES (5xx crashes,
  #                weird 4xx). A 500 is NOT a denial — it hides what the
  #                action would have rendered.
  # Each request uses a fresh IP so the per-IP rate limit doesn't mask
  # leaks that happen late in the sweep.
  def sweep(subdomain, allowlist: ANON_ALLOWED)
    host! "#{subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    leaks = []
    unexpected = []

    Rails.application.routes.routes.each do |route|
      next unless route.verb.match?("GET")

      ctrl = route.defaults[:controller]
      action = route.defaults[:action]
      next if ctrl.nil? || action.nil?
      next if SKIPPED_CONTROLLER_PREFIXES.any? { |p| ctrl.start_with?(p) }
      next unless inherits_from_application_controller?(ctrl)
      # Auth-flow controllers (sessions, signup, password resets, email
      # confirmation, 2FA, activation, reverification) override
      # is_auth_controller? to bypass the login requirement — these are
      # legitimately anon-reachable and outside our allows_anonymous system.
      next if is_auth_controller_action?(ctrl)
      # Pages that are public outside any auth system (e.g., the 404 page).
      next if OTHER_ANON_REACHABLE[ctrl]&.include?(action.to_sym)

      path = synthesize_path(route)
      next unless path
      next if SKIPPED_PATH_PREFIXES.any? { |p| path.start_with?(p) }

      begin
        get path, env: { "REMOTE_ADDR" => fresh_ip }
      rescue ActionController::UrlGenerationError, ActionController::RoutingError
        next
      rescue StandardError
        # Action raised for synthetic params (e.g., a controller call expects
        # a real fixture). The raise means no 2xx was rendered — treat as
        # "denied" and move on. (Distinct from a 500 response: a raise is
        # an unhandled exception, not a rendered status.)
        next
      end

      status = response.status
      if (200..299).cover?(status)
        unless allowlist[ctrl]&.include?(action.to_sym)
          leaks << "  GET #{path} → #{status} (controller=#{ctrl}, action=#{action})"
        end
      elsif !DENIAL_STATUSES.include?(status)
        unexpected << "  GET #{path} → #{status} (controller=#{ctrl}, action=#{action})"
      end
    end

    [leaks, unexpected]
  end

  # Build a request path from a route by stripping the format suffix and
  # substituting :params with a synthetic value. Returns nil for routes
  # we don't know how to exercise (wildcards, constraints we can't satisfy).
  def synthesize_path(route)
    spec = route.path.spec.to_s
    return nil if spec.include?("*")  # wildcard globs — skip

    spec = spec.sub(/\(\.:format\)$/, "")
    spec.gsub(/:[a-z_]+/) { "00000000" }
  end

  # Skip controllers that don't go through the ApplicationController bypass
  # chain. These (HealthcheckController, MetricsController, webhook
  # receivers) inherit from ActionController::Base and have their own auth
  # model — they are NOT subject to the allows_anonymous + bypass system
  # this test guards.
  def inherits_from_application_controller?(controller_name)
    klass = "#{controller_name.camelize}Controller".safe_constantize
    return false unless klass
    klass.ancestors.include?(ApplicationController)
  end

  # True when the controller overrides `is_auth_controller?` to return true.
  # These controllers (sessions, signup, password_resets, etc.) are exempt
  # from the login requirement in ApplicationController and are legitimately
  # anon-reachable. Not subject to the allows_anonymous bypass system.
  def is_auth_controller_action?(controller_name)
    klass = "#{controller_name.camelize}Controller".safe_constantize
    return false unless klass
    # The method is private, so use send. Returns true on a synthetic
    # instance — is_auth_controller? takes no request context.
    klass.new.send(:is_auth_controller?) rescue false
  end
end
