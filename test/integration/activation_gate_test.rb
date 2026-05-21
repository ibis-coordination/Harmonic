require "test_helper"

class ActivationGateTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "gate-test-#{SecureRandom.hex(4)}", name: "Gate Test")
    @host = create_user(email: "gate-host-#{SecureRandom.hex(4)}@example.com", name: "Gate Host")
    @tenant.add_user!(@host)
    @tenant.create_main_collective!(created_by: @host)
    @collective = @tenant.main_collective
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  test "fully activated human passes the gate (sign_in_as default)" do
    user = create_user(email: "ok-#{SecureRandom.hex(4)}@example.com", name: "OK User")
    sign_in_as(user, tenant: @tenant)  # default activates everything

    get "/"
    # Should NOT bounce to /activate — root resolves normally.
    assert_response :success
  end

  test "logged-in human without verified email gets bounced to /activate" do
    user = create_user(email: "noem-#{SecureRandom.hex(4)}@example.com", name: "No Email")
    sign_in_as(user, tenant: @tenant, activate: false)
    # Have 2FA but not email verification — only one item missing.
    identity = user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!

    get "/"
    assert_response :redirect
    assert_match(%r{/activate\z}, response.location)
  end

  test "logged-in human without 2FA gets bounced to /activate" do
    user = create_user(email: "no2-#{SecureRandom.hex(4)}@example.com", name: "No 2FA")
    sign_in_as(user, tenant: @tenant, activate: false)
    user.find_or_create_omni_auth_identity!.update!(email_confirmed_at: Time.current)

    get "/"
    assert_response :redirect
    assert_match(%r{/activate\z}, response.location)
  end

  test "gate doesn't fire on /activate itself (no infinite redirect)" do
    user = create_user(email: "self-#{SecureRandom.hex(4)}@example.com", name: "Self Route")
    sign_in_as(user, tenant: @tenant, activate: false)

    get "/activate"
    assert_response :success
  end

  test "gate doesn't fire on /confirm-email/:token (token-authenticated)" do
    user = create_user(email: "etok-#{SecureRandom.hex(4)}@example.com", name: "ETok User")
    identity = user.find_or_create_omni_auth_identity!
    # Give it a password so the identity is valid
    identity.update!(password: "validpassword123", password_confirmation: "validpassword123")
    raw = identity.send_email_confirmation!
    sign_in_as(user, tenant: @tenant, activate: false)

    get "/confirm-email/#{raw}"
    assert_response :success
  end

  test "gate doesn't fire when tenant doesn't require either 2FA or verified email" do
    user = create_user(email: "fr-#{SecureRandom.hex(4)}@example.com", name: "Free Tenant User")
    @tenant.settings["require_2fa"] = false
    @tenant.settings["require_verified_email"] = false
    @tenant.save!
    sign_in_as(user, tenant: @tenant, activate: false)

    get "/"
    assert_response :success
  end

  test "gate doesn't fire for sys_admin users" do
    admin = create_user(email: "sa-#{SecureRandom.hex(4)}@example.com", name: "SysAdmin Bypass")
    admin.update!(sys_admin: true)
    sign_in_as(admin, tenant: @tenant, activate: false)

    get "/"
    assert_response :success
  end

  test "gate doesn't fire when an API token is used (api request gets its own check)" do
    user = create_user(email: "api-#{SecureRandom.hex(4)}@example.com", name: "API User")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    token = ApiToken.create!(user: user, tenant: @tenant, name: "T", scopes: ["read:all"])

    get "/api/v1/notes",
        headers: {
          "Authorization" => "Bearer #{token.plaintext_token}",
          "Accept" => "application/json",
        }
    # Whatever the response is, it must NOT be a redirect to /activate.
    assert_no_match %r{/activate}, response.headers["Location"].to_s
  end

  test "gate preserves the user's original destination via session[:activation_return_to]" do
    user = create_user(email: "ret-#{SecureRandom.hex(4)}@example.com", name: "Return To User")
    sign_in_as(user, tenant: @tenant, activate: false)

    get "/u/#{user.tenant_users.first.handle}"
    assert_redirected_to "/activate"
    assert_equal "/u/#{user.tenant_users.first.handle}", session[:activation_return_to]
  end

end
