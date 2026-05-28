require "test_helper"

# End-to-end tests for the 6-condition anonymous-read bypass in
# ApplicationController#validate_unauthenticated_access. Verifies that:
#
# 1. With all 6 conditions met, anon GET succeeds (200 HTML / 200 markdown).
# 2. With ANY condition unmet, anon request is redirected to /login (or 404'd
#    for nonexistent resources).
#
# Relies on the permanent `allows_anonymous` declarations in
# NotesController / DecisionsController / CommitmentsController /
# HelpController — this file sets up only the env-var fixture and the
# per-tenant data.
class AnonymousReadAccessBypassTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "anonbypasspublic".freeze
  PRIVATE_SUBDOMAIN = "anonbypassprivate".freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!
    set_up_public_tenant
    set_up_private_tenant
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

  private

  def set_up_public_tenant
    @public_tenant = Tenant.create!(subdomain: PUBLIC_SUBDOMAIN, name: "Public Tenant")
    @public_user = User.create!(email: "publicowner@example.com", name: "Public Owner", user_type: "human")
    @public_tenant.add_user!(@public_user)
    @public_tenant.create_main_collective!(created_by: @public_user)
    @public_main = @public_tenant.main_collective
    @public_other_collective = Collective.create!(
      tenant: @public_tenant,
      created_by: @public_user,
      name: "Public Other Collective",
      handle: "public-other-collective"
    )
    @public_other_collective.add_user!(@public_user)

    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@public_main)
    @public_note = create_note(tenant: @public_tenant, collective: @public_main, created_by: @public_user)
    @public_decision = create_decision(tenant: @public_tenant, collective: @public_main, created_by: @public_user)
    @public_commitment = create_commitment(tenant: @public_tenant, collective: @public_main, created_by: @public_user)
    Collective.set_thread_context(@public_other_collective)
    @public_other_note = create_note(tenant: @public_tenant, collective: @public_other_collective, created_by: @public_user)
  end

  def set_up_private_tenant
    @private_tenant = Tenant.create!(subdomain: PRIVATE_SUBDOMAIN, name: "Private Tenant")
    @private_user = User.create!(email: "privateowner@example.com", name: "Private Owner", user_type: "human")
    @private_tenant.add_user!(@private_user)
    @private_tenant.create_main_collective!(created_by: @private_user)
    @private_main = @private_tenant.main_collective

    Tenant.scope_thread_to_tenant(subdomain: PRIVATE_SUBDOMAIN)
    Collective.set_thread_context(@private_main)
    @private_note = create_note(tenant: @private_tenant, collective: @private_main, created_by: @private_user)
    @private_decision = create_decision(tenant: @private_tenant, collective: @private_main, created_by: @private_user)
    @private_commitment = create_commitment(tenant: @private_tenant, collective: @private_main, created_by: @private_user)
  end

  # ---- Condition 2 (public tenant): rejected on private tenant ----

  test "anon GET /n/:id on PRIVATE tenant redirects to login" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @private_note.path
    assert_redirected_to %r{/login}
  end

  test "anon GET /d/:id on PRIVATE tenant redirects to login" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @private_decision.path
    assert_redirected_to %r{/login}
  end

  test "anon GET /c/:id on PRIVATE tenant redirects to login" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @private_commitment.path
    assert_redirected_to %r{/login}
  end

  test "anon GET /help on PRIVATE tenant redirects to login" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help"
    assert_redirected_to %r{/login}
  end

  test "anon GET /help/privacy on PRIVATE tenant redirects to login" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help/privacy"
    assert_redirected_to %r{/login}
  end

  # ---- Condition 3 (main collective): rejected when collective_handle is non-main ----

  test "anon GET on PUBLIC tenant with collective_handle (non-main) redirects to login" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @public_other_note.path
    assert_redirected_to %r{/login}
  end

  # ---- Condition 4 (GET/HEAD): non-GET rejected ----

  test "anon POST /n/:id/comments on PUBLIC tenant redirects to login (not GET)" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    post "#{@public_note.path}/comments", params: { text: "hi" }
    assert_redirected_to %r{/login}
  end

  # ---- Condition 6 (HTML/MD format): JSON rejected, */* and mixed accept allowed ----

  test "anon GET /n/:id with Accept: application/json on PUBLIC tenant is rejected (401/302)" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @public_note.path, headers: { "Accept" => "application/json" }
    assert_includes [302, 401, 406], response.status,
                    "expected JSON request to be rejected, got #{response.status}"
  end

  test "anon GET /n/:id with Accept: */* (curl/monitor default) returns 200 HTML" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @public_note.path, headers: { "Accept" => "*/*" }
    assert_response :success
    assert_equal "text/html", response.media_type
  end

  test "anon GET /n/:id with browser-style Accept (text/html,...,*/*) returns 200 HTML" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    browser_accept = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
    get @public_note.path, headers: { "Accept" => browser_accept }
    assert_response :success
    assert_equal "text/html", response.media_type
  end

  # ---- Conditions 1-6 ALL met: success on public tenant ----

  test "anon GET /n/:id on PUBLIC main collective returns 200 HTML" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @public_note.path
    assert_response :success
    assert_equal "text/html", response.media_type
  end

  test "anon GET /n/:id with Accept: text/markdown on PUBLIC tenant returns 200 markdown" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @public_note.path, headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_equal "text/markdown", response.media_type
  end

  test "anon GET /d/:id on PUBLIC main collective returns 200 HTML" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @public_decision.path
    assert_response :success
  end

  test "anon GET /c/:id on PUBLIC main collective returns 200 HTML" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @public_commitment.path
    assert_response :success
  end

  test "anon GET /help on PUBLIC tenant returns 200 HTML" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help"
    assert_response :success
  end

  test "anon GET /help/privacy on PUBLIC tenant returns 200 HTML" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help/privacy"
    assert_response :success
  end

  # ---- No-write invariants on public-tenant anon GET ----

  test "anon GET /d/:id on PUBLIC tenant does NOT create a DecisionParticipant" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    before = DecisionParticipant.unscoped.count
    get @public_decision.path
    assert_response :success
    assert_equal before, DecisionParticipant.unscoped.count,
                 "anon GET must not create a DecisionParticipant row"
  end

  test "anon GET /c/:id on PUBLIC tenant does NOT create a CommitmentParticipant" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    before = CommitmentParticipant.unscoped.count
    get @public_commitment.path
    assert_response :success
    assert_equal before, CommitmentParticipant.unscoped.count,
                 "anon GET must not create a CommitmentParticipant row"
  end

  # ---- Nonexistent resource: still returns 404 (not redirect) ----

  test "anon GET nonexistent /n/:id on PUBLIC tenant returns 404 (resource resolution still runs)" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/n/00000000"
    assert_response :not_found
  end

  # ---- No-crash sanity ----

  test "anon GET on PUBLIC tenant does not raise" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    assert_nothing_raised do
      get @public_note.path
    end
  end
end
