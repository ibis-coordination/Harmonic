require "test_helper"

# Phase 3 view-suppression sweep. Anon viewers on a public main collective
# should:
#   - See content (note body, decision options, commitment status, comments,
#     attachments, backlinks)
#   - NOT see logged-in-only interaction surfaces (pin button, report button,
#     comment form input, etc.)
#   - Get "Log in to <verb>" CTAs where a logged-in user would have an
#     interaction surface, so the affordance isn't silently missing.
class AnonymousReadAccessViewsTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "anonviewspublic".freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!

    @tenant = Tenant.create!(subdomain: PUBLIC_SUBDOMAIN, name: "Public")
    @user = User.create!(email: "viewsowner@example.com", name: "Owner", user_type: "human")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
    @main = @tenant.main_collective

    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@main)
    @note = create_note(tenant: @tenant, collective: @main, created_by: @user)
    @decision = create_decision(tenant: @tenant, collective: @main, created_by: @user)
    @commitment = create_commitment(tenant: @tenant, collective: @main, created_by: @user)
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    @test_ip = "10.#{SecureRandom.random_number(256)}.#{SecureRandom.random_number(256)}.#{SecureRandom.random_number(254) + 1}"
  end

  def teardown
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def process(method, path, **kwargs)
    if @test_ip
      env = (kwargs[:env] || {}).dup
      env["REMOTE_ADDR"] ||= @test_ip
      kwargs = kwargs.merge(env: env)
    end
    super
  end

  # ---- Anon sees "Log in to comment" CTA on commentable show pages ----
  #
  # Note: /n/:id does NOT render the comments section inline — it fetches it
  # async from /n/:id/comments.html, which isn't on the anon-allowed list per
  # the plan ("The three item URLs"). So anon viewers don't see comments on
  # note pages, consistent with the documented scope.

  test "anon GET /d/:id shows a Log in to comment CTA" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @decision.path
    assert_response :success
    assert_match(/Log in.*to comment/m, response.body)
  end

  test "anon GET /c/:id shows a Log in to comment CTA" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @commitment.path
    assert_response :success
    assert_match(/Log in.*to comment/m, response.body)
  end

  test "logged-in GET /d/:id renders the comment FORM, NOT the anon CTA" do
    sign_in_as(@user, tenant: @tenant)
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @decision.path
    assert_response :success
    assert_match(/Add Comment/, response.body, "expected comment form button for logged-in user")
    assert_no_match(/Log in.*to comment/m, response.body)
  end

  # ---- Anon does NOT see logged-in-only interaction surfaces ----

  test "anon GET /n/:id does NOT show pin button" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @note.path
    # The pin button is rendered as part of the kebab menu; for anon, neither
    # the pin nor the report buttons render, so the kebab menu doesn't appear.
    assert_no_match(/data-pin-target/, response.body)
  end

  test "anon GET /n/:id does NOT show report button" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @note.path
    assert_no_match(/Report Content/, response.body)
  end

  test "anon GET /n/:id does NOT show edit button" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @note.path
    # The edit link sends to "#{note.path}/edit" — match defensively.
    assert_no_match(%r{#{Regexp.escape(@note.path)}/edit"}, response.body)
  end

  # ---- Top-right menu shows Log in / Sign up for anon, not user menu ----

  test "anon top-right chrome shows Log in, not notifications/profile menu" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @note.path
    assert_match(/Log in/, response.body)
    # Notification bell only renders for @current_user
    assert_no_match(/notification.*unread/i, response.body)
  end
end
