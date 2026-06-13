require "test_helper"

# End-to-end coverage for the invite-code memory mechanism that survives
# the OAuth round-trip. Previously untested even though it is the single
# load-bearing path for invited signup.
#
# Real OAuth provider calls are not exercised; the test simulates the
# /login -> auth-domain -> /login/callback flow using the same encrypted
# token mechanism the OAuth callback uses internally. The redirect_to_subdomain
# cookie set by /login on the tenant subdomain is cleared by the auth
# subdomain handler in the real flow; we simulate that intermediate clearing
# by bypassing the first /login GET for callback-half tests.
class InviteSignupFlowTest < ActionDispatch::IntegrationTest
  def setup
    @host_tenant = create_tenant(subdomain: "host-#{SecureRandom.hex(4)}", name: "Host Tenant")
    @host_user = create_user(email: "host-#{SecureRandom.hex(4)}@example.com", name: "Host")
    @host_tenant.add_user!(@host_user)
    @host_tenant.create_main_collective!(created_by: @host_user)
    @target_collective = create_collective(
      tenant: @host_tenant,
      created_by: @host_user,
      handle: "target-#{SecureRandom.hex(4)}"
    )
    @target_collective.add_user!(@host_user)
    @invited_user = create_user(email: "invitee-#{SecureRandom.hex(4)}@example.com", name: "Invitee")
  end

  def tenant_host(tenant)
    "#{tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def generate_test_token(tenant, user)
    derived_key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
      .generate_key("cross_subdomain_token", 32)
    crypt = ActiveSupport::MessageEncryptor.new(derived_key)
    timestamp = Time.current.to_i
    crypt.encrypt_and_sign("#{tenant.id}:#{user.id}:#{timestamp}")
  end

  def create_invite(collective: @target_collective, invited_user: nil, expires_at: 1.week.from_now)
    Invite.create!(
      tenant: @host_tenant,
      collective: collective,
      created_by: @host_user,
      invited_user: invited_user,
      code: SecureRandom.hex(8),
      expires_at: expires_at
    )
  end

  # Half 1: the cookie is set when an unauthenticated user hits /login?code=X
  test "/login with an invite code sets the collective_invite_code cookie before bouncing to auth subdomain" do
    invite = create_invite

    host! tenant_host(@host_tenant)
    get "/login", params: { code: invite.code }

    assert_response :redirect
    assert_match(/#{ENV.fetch("AUTH_SUBDOMAIN", nil)}/, response.location,
                 "expected redirect to auth subdomain")
    assert_equal invite.code, cookies[:collective_invite_code],
                 "expected invite cookie set so it survives the OAuth round-trip"
  end

  # Half 2: when the callback fires with the invite cookie present, a brand-new
  # user is routed to the invite confirmation page. Joining the tenant happens
  # only when they explicitly accept there — never silently during login.
  test "callback with invite cookie routes a new user to the confirmation page without joining the tenant" do
    invite = create_invite

    host! tenant_host(@host_tenant)
    cookies[:collective_invite_code] = invite.code
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    get "/login/callback"

    assert_response :redirect
    assert_match(%r{/invite-required\?code=#{invite.code}}, response.location,
                 "expected to land on the invite confirmation page after callback")
    assert_equal invite.code, session[:pending_invite_codes][@host_tenant.id],
                 "expected the invite code stashed per-tenant in the session for the activation flow"
    assert_equal @invited_user.id, session[:user_id],
                 "expected user to be signed in after callback"
    assert_not @host_tenant.tenant_users.exists?(user: @invited_user),
               "tenant join must wait for explicit acceptance"
  end

  test "callback with invite cookie routes an existing tenant member straight to the collective join page" do
    invite = create_invite
    @host_tenant.add_user!(@invited_user)

    host! tenant_host(@host_tenant)
    cookies[:collective_invite_code] = invite.code
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    get "/login/callback"

    assert_response :redirect
    assert_match(%r{#{Regexp.escape(@target_collective.path)}/join},
                 response.location,
                 "members invited to another collective accept on the collective join page")
    assert_match(/code=#{invite.code}/, response.location)
  end

  test "logged-in non-member visiting a collective join link is routed to confirmation, not silently added to the tenant" do
    invite = create_invite

    host! tenant_host(@host_tenant)
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)
    get "/login/callback" # signs in, redirects to /invite-required

    get "#{@target_collective.path}/join", params: { code: invite.code }

    assert_response :redirect
    assert_match(%r{/invite-required\?code=#{invite.code}}, response.location,
                 "expected redirect to the confirmation flow instead of the join page")
    assert_not @host_tenant.tenant_users.exists?(user: @invited_user),
               "visiting a join link must not create a TenantUser"
  end

  test "full journey: callback routes to confirmation page where explicit accept joins tenant and collective" do
    invite = create_invite

    host! tenant_host(@host_tenant)
    cookies[:collective_invite_code] = invite.code
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    get "/login/callback"
    follow_redirect!

    assert_response :success
    assert_match(/#{Regexp.escape(@target_collective.name)}/, response.body,
                 "confirmation page should name the collective the user is about to join")
    assert_select "form[action='/invite-required/accept']"

    post "/invite-required/accept", params: { code: invite.code }

    assert_response :redirect
    assert @host_tenant.tenant_users.exists?(user: @invited_user),
           "expected TenantUser created on explicit accept"
    assert @target_collective.user_is_member?(@invited_user),
           "expected CollectiveMember created on explicit accept"
    assert_nil session[:pending_invite_codes],
               "expected pending invite cleared from session after acceptance"
  end

  test "callback clears the invite cookie after consuming it" do
    invite = create_invite

    host! tenant_host(@host_tenant)
    cookies[:collective_invite_code] = invite.code
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    get "/login/callback"

    assert_nil cookies[:collective_invite_code].presence,
               "expected invite cookie to be cleared after callback handled it"
  end

  test "a leftover redirect_to_resource cookie does not starve the invite" do
    # Both shared-domain cookies can coexist (set by separate /login visits).
    # The resource redirect may win the post-login routing, but the invite
    # must still be consumed into the session so the signup flow can recover.
    invite = create_invite

    host! tenant_host(@host_tenant)
    cookies[:collective_invite_code] = invite.code
    cookies[:redirect_to_resource] = "/n/abc123"
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    get "/login/callback"

    assert_equal invite.code, session[:pending_invite_codes][@host_tenant.id],
                 "the pending invite must survive whichever redirect wins"
    assert_nil cookies[:collective_invite_code].presence,
               "the invite cookie is consumed even when the resource redirect wins"
  end

  test "expired invite via cookie does not grant collective membership" do
    expired = create_invite(expires_at: 1.day.ago)

    host! tenant_host(@host_tenant)
    cookies[:collective_invite_code] = expired.code
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    get "/login/callback"

    assert_not @target_collective.user_is_member?(@invited_user),
               "expected expired invite not to grant collective membership"
    assert_nil session[:pending_invite_codes],
               "expected no pending invite stashed for an expired code"
  end

  test "signed-in non-member hitting any page must NOT receive a spurious CollectiveMember from the redirect path" do
    # Regression: validate_authenticated_access used to fall through after
    # redirecting (no `return`), reaching the main-collective add_user! branch
    # below and creating a CollectiveMember for a user who isn't even a
    # tenant member yet. This left orphan rows tying non-members to the
    # main collective.
    main = @host_tenant.main_collective
    host! tenant_host(@host_tenant)
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    # First request: log in via the callback (redirects to /invite-required).
    get "/login/callback"
    assert_response :redirect

    # Second request: simulate the user navigating to any non-signup page.
    get "/"
    assert_response :redirect
    assert_match(%r{/invite-required$}, response.location)
    assert_not main.user_is_member?(@invited_user),
               "expected no CollectiveMember to be created on the redirect path"
    assert_not @host_tenant.tenant_users.exists?(user: @invited_user),
               "expected no TenantUser to be created on the redirect path"
  end

  test "callback without invite cookie and no tenant membership redirects to /invite-required" do
    host! tenant_host(@host_tenant)
    cookies[:token] = generate_test_token(@host_tenant, @invited_user)

    get "/login/callback"

    assert_response :redirect
    assert_match(%r{/invite-required$}, response.location)
    assert_equal @invited_user.id, session[:user_id]
    assert_not @host_tenant.tenant_users.exists?(user: @invited_user),
               "no auto-join on require_invite tenant"
  end
end
