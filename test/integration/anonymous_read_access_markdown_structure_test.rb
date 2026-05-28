require "test_helper"
require "yaml"

# Structural assertions on the anon markdown surface for /n/:id, /d/:id,
# /c/:id, /u/:handle, and /help.
#
# These tests fall into two categories:
#
# 1. **Property tests** (frontmatter whitelist, Actions section absence) —
#    these guard a STRUCTURAL property of the rendered markdown. They catch
#    any future change that violates the property, including changes
#    unrelated to the specific code paths they exercise.
#
# 2. **Phrase pins** (the explicit string-search assertions for "Logged in
#    as", "Submit your vote", etc.) — these guard specific known leak
#    phrases. They are NOT exhaustive. A future leak that uses different
#    wording (e.g., "Your last read at: …") would pass these tests and
#    ship. The value is regression prevention for the exact strings listed,
#    not a general "no per-viewer data" guard.
#
# A real "no per-viewer data" test would diff the anon body against the
# logged-in body with a whitelisted set of allowed differences. That's
# complex to write cleanly; the property tests are the load-bearing
# protection here.
class AnonymousReadAccessMarkdownStructureTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "anonmdpublic".freeze

  # Whitelist of frontmatter keys the layout is allowed to emit for anon.
  # Any new layout-level key must be reviewed for per-viewer-data leakage
  # before being added here. Also indirectly covers the `actions:` key
  # (omitted because available_actions_for_current_route returns [] for anon).
  ANON_ALLOWED_FRONTMATTER_KEYS = %w[app host path title timestamp].freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!

    @tenant = Tenant.create!(subdomain: PUBLIC_SUBDOMAIN, name: "Public")
    @user = User.create!(email: "mdowner@example.com", name: "Markdown Owner", user_type: "human")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
    @main = @tenant.main_collective
    @user_handle = @tenant.tenant_users.find_by(user: @user).handle

    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@main)
    @note = create_note(tenant: @tenant, collective: @main, created_by: @user, title: "MD note")
    @decision = create_decision(tenant: @tenant, collective: @main, created_by: @user, question: "MD decision?")
    # Add an option so the markdown decision template exercises the "Options"
    # branch with vote-instruction text — needed for the PIN tests below to
    # catch real leaks.
    create_option(tenant: @tenant, collective: @main, created_by: @user, decision: @decision, title: "Option A")
    @commitment = create_commitment(tenant: @tenant, collective: @main, created_by: @user, title: "MD commitment")
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    @test_ip = fresh_test_ip
    self.remote_addr = @test_ip
  end

  def teardown
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  # ---- Helpers ----

  def fetch_md(path)
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get path, headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_equal "text/markdown", response.media_type
    response.body
  end

  def parse_frontmatter(body)
    m = body.match(/\A---\n(.*?)\n---\n/m)
    return {} unless m
    YAML.safe_load(m[1], permitted_classes: [Time, Date, Symbol]) || {}
  end

  # ---- PROPERTY: frontmatter is restricted to the anon whitelist ----
  #
  # Catches: any new layout-level frontmatter key emitted for anon
  # (including `actions:`, per-viewer state, draft refs, etc.).

  test "anon /n/:id markdown frontmatter has only the anon-allowed keys" do
    fm = parse_frontmatter(fetch_md(@note.path))
    leaked = fm.keys - ANON_ALLOWED_FRONTMATTER_KEYS
    assert_empty leaked, "anon markdown leaked frontmatter keys: #{leaked.inspect}"
  end

  test "anon /d/:id markdown frontmatter has only the anon-allowed keys" do
    fm = parse_frontmatter(fetch_md(@decision.path))
    leaked = fm.keys - ANON_ALLOWED_FRONTMATTER_KEYS
    assert_empty leaked, "leaked: #{leaked.inspect}"
  end

  test "anon /c/:id markdown frontmatter has only the anon-allowed keys" do
    fm = parse_frontmatter(fetch_md(@commitment.path))
    leaked = fm.keys - ANON_ALLOWED_FRONTMATTER_KEYS
    assert_empty leaked, "leaked: #{leaked.inspect}"
  end

  test "anon /u/:handle markdown frontmatter has only the anon-allowed keys" do
    fm = parse_frontmatter(fetch_md("/u/#{@user_handle}"))
    leaked = fm.keys - ANON_ALLOWED_FRONTMATTER_KEYS
    assert_empty leaked, "leaked: #{leaked.inspect}"
  end

  # ---- PROPERTY: no "## Actions" body section for anon ----
  #
  # The Actions footer is rendered by templates that hard-code "## Actions"
  # (e.g., app_admin, automations). None of the anon-allowed show pages
  # render it today. This guards against a future template change that
  # would expose it to anon.

  test "anon markdown bodies do not contain a `## Actions` section header" do
    [@note.path, @decision.path, @commitment.path, "/u/#{@user_handle}"].each do |path|
      assert_no_match(/^## Actions\b/m, fetch_md(path),
                      "anon markdown rendered an Actions section header for #{path}")
    end
  end

  # ---- PIN: known per-viewer phrases ----
  #
  # These are NOT exhaustive. They pin the specific strings noticed during
  # the markdown audit. A new leak in different wording would pass these
  # tests. Treat them as regression guards for the listed phrases only.

  test "PIN: anon markdown nav does not contain 'Logged in as' (layout nav guard)" do
    [@note.path, @decision.path, @commitment.path, "/u/#{@user_handle}", "/help", "/help/privacy"].each do |path|
      assert_no_match(/Logged in as/, fetch_md(path), "leaked in #{path}")
    end
  end

  test "PIN: anon markdown does not contain 'acting on behalf of' (representation chrome)" do
    assert_no_match(/acting on behalf of/, fetch_md(@note.path))
  end

  test "PIN: anon /d/:id markdown does not contain 'Submit your vote'" do
    body = fetch_md(@decision.path)
    assert_no_match(/Submit your vote/i, body,
                    "anon viewers were once told to submit a vote — they can't")
    assert_no_match(/your vote|you voted/i, body)
  end

  test "PIN: anon /d/:id markdown does not contain vote instructions ('that you would accept', 'options you prefer')" do
    # The "Check ✅ all options that you would accept. Star ⭐️ options you
    # prefer." instructions don't make sense for anon viewers who can't vote.
    body = fetch_md(@decision.path)
    assert_no_match(/that you would accept/i, body)
    assert_no_match(/options you prefer/i, body)
  end
end
