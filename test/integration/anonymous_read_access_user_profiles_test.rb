require "test_helper"

# Anon read access for user profile pages `/u/:handle`. Profiles are
# tenant-level resources but the show action renders the user's main-collective
# activity feed, so the bypass treats them like main-collective content
# (collective-scoped variants /collectives/X/u/:handle still 302 because
# bypass condition 3 fails).
#
# Covered:
#   - Human, AI-agent, collective-identity user types all anon-viewable
#   - Archived user profile renders with the badge (still anon-viewable)
#   - Logged-in-only chrome (Settings, Message, Block buttons) hidden for anon
#   - Activity feed visible for anon
#   - Markdown response works
#   - 404 for nonexistent handle, 302 for collective-scoped or private tenant
class AnonymousReadAccessUserProfilesTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "anonuserpublic".freeze
  PRIVATE_SUBDOMAIN = "anonuserprivate".freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!
    set_up_public_tenant
    set_up_private_tenant
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    @test_ip = "10.#{rand(256)}.#{rand(256)}.#{rand(1..254)}"
  end

  def teardown
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def process(method, path, **kwargs)
    env = (kwargs[:env] || {}).dup
    env["REMOTE_ADDR"] ||= @test_ip
    super(method, path, **kwargs.merge(env: env))
  end

  private

  def set_up_public_tenant
    @public_tenant = Tenant.create!(subdomain: PUBLIC_SUBDOMAIN, name: "Public")
    @human = User.create!(email: "human@example.com", name: "Visible Human", user_type: "human")
    @public_tenant.add_user!(@human)
    @public_tenant.create_main_collective!(created_by: @human)
    @main = @public_tenant.main_collective
    @human_handle = @public_tenant.tenant_users.find_by(user: @human).handle

    @ai_agent = create_ai_agent(parent: @human, name: "Visible Agent")
    @public_tenant.add_user!(@ai_agent)
    @ai_agent_handle = @public_tenant.tenant_users.find_by(user: @ai_agent).handle

    @collective_identity = User.create!(email: "ci@example.com", name: "Visible CI", user_type: "collective_identity")
    @public_tenant.add_user!(@collective_identity)
    @ci_handle = @public_tenant.tenant_users.find_by(user: @collective_identity).handle

    # Archival is on TenantUser, not User.
    @archived = User.create!(email: "archived@example.com", name: "Archived User", user_type: "human")
    archived_tu = @public_tenant.add_user!(@archived)
    @archived_handle = archived_tu.handle
    archived_tu.update!(archived_at: Time.current)

    # A note in the main collective so the activity-feed assertion has content.
    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@main)
    @human_note = create_note(tenant: @public_tenant, collective: @main, created_by: @human, title: "Human activity note")
  end

  def set_up_private_tenant
    @private_tenant = Tenant.create!(subdomain: PRIVATE_SUBDOMAIN, name: "Private")
    @private_user = User.create!(email: "private@example.com", name: "Private", user_type: "human")
    @private_tenant.add_user!(@private_user)
    @private_tenant.create_main_collective!(created_by: @private_user)
    @private_handle = @private_tenant.tenant_users.find_by(user: @private_user).handle
  end

  # ---- Declaration ----

  test "UsersController declares allows_anonymous :show" do
    assert UsersController.allows_anonymous?(:show)
  end

  # ---- Anon happy paths ----

  test "anon GET /u/:handle (human) returns 200 HTML with display name" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_response :success
    assert_equal "text/html", response.media_type
    assert_match(/Visible Human/, response.body)
  end

  test "anon GET /u/:handle with Accept: text/markdown returns 200 markdown" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_match(/Visible Human/, response.body)
  end

  test "anon GET /u/:handle (ai_agent) returns 200" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@ai_agent_handle}"
    assert_response :success
    assert_match(/Visible Agent/, response.body)
  end

  test "anon GET /u/:handle (collective_identity) returns 200" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@ci_handle}"
    assert_response :success
    assert_match(/Visible CI/, response.body)
  end

  test "anon GET /u/:handle (archived) returns 200 with Archived badge" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@archived_handle}"
    assert_response :success
    assert_match(/Archived/, response.body)
  end

  test "anon GET /u/:handle includes activity feed item for the user" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_response :success
    assert_match(/Human activity note/, response.body)
  end

  test "anon GET /u/:handle feed-item NOTE shows Log-in CTA, no Confirm-read button" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_response :success
    assert_match(/Log in.*to confirm reading/m, response.body)
    assert_no_match(/data-pulse-action-url-value="[^"]*\/actions\/confirm_read"/, response.body,
                    "no active Confirm-read button on feed item for anon")
  end

  test "anon GET /u/:handle feed-item DECISION shows Log-in CTA, no Vote link" do
    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@main)
    create_decision(tenant: @public_tenant, collective: @main, created_by: @human, question: "Profile decision?")
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_response :success
    assert_match(/Log in.*to vote/m, response.body)
    assert_no_match(/class="pulse-feed-action-btn-link"[^>]*>[^<]*Vote/, response.body,
                    "no active Vote link on feed item for anon")
  end

  test "anon GET /u/:handle feed-item COMMITMENT shows Log-in CTA, no join button" do
    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@main)
    create_commitment(tenant: @public_tenant, collective: @main, created_by: @human, title: "Profile commitment")
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_response :success
    assert_match(/Log in.*to (join|sign|rsvp)/im, response.body)
    assert_no_match(/data-pulse-action-url-value="[^"]*\/actions\/join_commitment"/, response.body,
                    "no active join button on feed item for anon")
  end

  test "anon GET /u/:handle sets Cache-Control: private, no-store" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  # ---- Anon negative paths ----

  test "anon GET /u/:handle on PRIVATE tenant redirects to login" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@private_handle}"
    assert_redirected_to %r{/login}
  end

  test "anon GET /collectives/<handle>/u/:handle on PUBLIC tenant redirects to login (non-main collective)" do
    other = Collective.create!(
      tenant: @public_tenant,
      created_by: @human,
      name: "Other",
      handle: "anonuserother"
    )
    other.add_user!(@human)
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/collectives/#{other.handle}/u/#{@human_handle}"
    assert_redirected_to %r{/login}
  end

  test "anon GET /u/nonexistent returns 404 (no 302)" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/no-such-handle"
    assert_response :not_found
  end

  # ---- Logged-in-only chrome is hidden for anon ----

  test "anon GET /u/:handle does NOT show Settings/Message/Block buttons" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_no_match(%r{href="[^"]*/settings"}, response.body, "no settings link")
    assert_no_match(/title="Message"/, response.body, "no message button")
    assert_no_match(/Block @#{Regexp.escape(@human_handle)}/, response.body, "no block button")
  end

  # ---- Logged-in viewer still sees their chrome ----

  test "logged-in GET /u/:handle (own profile) shows Settings link" do
    sign_in_as(@human, tenant: @public_tenant)
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/u/#{@human_handle}"
    assert_response :success
    assert_match(%r{/u/#{Regexp.escape(@human_handle)}/settings}, response.body)
  end
end
