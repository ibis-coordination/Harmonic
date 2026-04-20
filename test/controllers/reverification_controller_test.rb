# typed: false
require "test_helper"

class ReverificationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.find_by(subdomain: ENV["PRIMARY_SUBDOMAIN"]) ||
              Tenant.create!(subdomain: ENV["PRIMARY_SUBDOMAIN"], name: "Primary")
    @tenant.create_main_collective!(created_by: create_user(name: "System")) unless @tenant.main_collective

    @user = create_user(name: "Reverify Controller User")
    @tenant.add_user!(@user)

    @identity = @user.find_or_create_omni_auth_identity!
    @identity.generate_otp_secret!
    @identity.enable_otp!

    host! "#{@tenant.subdomain}.#{ENV["HOSTNAME"]}"
  end

  test "GET /reverify renders the TOTP form" do
    sign_in_as(@user, tenant: @tenant)

    get "/reverify"
    assert_response :success
    assert_match(/authenticator app/i, response.body)
  end

  test "POST /reverify with valid TOTP sets session and redirects" do
    sign_in_as(@user, tenant: @tenant)

    # Set a return URL in session (normally done by the concern)
    get "/reverify" # need a request to establish session first

    totp = ROTP::TOTP.new(@identity.otp_secret)
    post "/reverify", params: { code: totp.now }

    # Should redirect (to return URL or root)
    assert_response :redirect
  end

  test "POST /reverify with invalid TOTP shows error" do
    sign_in_as(@user, tenant: @tenant)

    post "/reverify", params: { code: "000000" }
    assert_response :success # re-renders form
    assert_match(/invalid/i, response.body)
  end

  test "POST /reverify when locked out shows lockout message" do
    sign_in_as(@user, tenant: @tenant)

    # Exhaust attempts to trigger lockout
    10.times { @identity.verify_otp("000000") }
    assert @identity.otp_locked?, "identity should be locked after failed attempts"

    post "/reverify", params: { code: "000000" }
    assert_response :success
    assert_match(/locked/i, response.body)
  end

  test "GET /reverify redirects to login when not authenticated" do
    get "/reverify"
    # Should redirect to login (not crash)
    assert_response :redirect
  end

  test "POST /reverify with valid code redirects to root when no return URL" do
    sign_in_as(@user, tenant: @tenant)

    totp = ROTP::TOTP.new(@identity.otp_secret)
    post "/reverify", params: { code: totp.now }

    assert_redirected_to "/"
  end

  test "POST /reverify replays stashed non-GET request after successful verification" do
    sign_in_as(@user, tenant: @tenant)
    handle = @tenant.tenant_users.find_by(user: @user).handle

    # Trigger reverification by PATCHing a protected endpoint.
    # The concern stashes the method+params, then redirects to /reverify.
    patch "/u/#{handle}/settings/email", params: { email: "replayed@example.com" }
    assert_redirected_to "/reverify"

    # Verify with valid TOTP
    totp = ROTP::TOTP.new(@identity.otp_secret)
    post "/reverify", params: { code: totp.now }

    # Should redirect to the replay page
    assert_redirected_to "/reverify/replay"

    # Follow redirect — replay page renders auto-submit form
    follow_redirect!
    assert_response :success
    assert_match(/replayed@example\.com/, response.body)
    assert_match(/patch/i, response.body)
  end
end
