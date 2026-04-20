# typed: false
require "test_helper"

# Tests for RequiresReverification concern.
# Uses the system admin dashboard as the protected endpoint.
class RequiresReverificationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.find_by(subdomain: ENV["PRIMARY_SUBDOMAIN"]) ||
              Tenant.create!(subdomain: ENV["PRIMARY_SUBDOMAIN"], name: "Primary")
    @tenant.create_main_collective!(created_by: create_user(name: "System")) unless @tenant.main_collective

    @user = create_user(name: "Reverify Test User")
    @user.update!(sys_admin: true)
    @tenant.add_user!(@user)

    @identity = @user.find_or_create_omni_auth_identity!
    @identity.generate_otp_secret!
    @identity.enable_otp!

    host! "#{@tenant.subdomain}.#{ENV["HOSTNAME"]}"
  end

  # Helper: sign in, trigger reverification redirect, verify with TOTP
  def sign_in_and_reverify!
    sign_in_as(@user, tenant: @tenant)
    get "/system-admin" # triggers redirect + stores scope in session
    totp = ROTP::TOTP.new(@identity.otp_secret)
    post "/reverify", params: { code: totp.now }
  end

  test "redirects to /reverify when no reverification in session" do
    sign_in_as(@user, tenant: @tenant)
    get "/system-admin"
    assert_redirected_to "/reverify"
  end

  test "allows access when recently reverified" do
    sign_in_and_reverify!
    get "/system-admin"
    assert_response :success
  end

  test "redirects when reverification has expired" do
    sign_in_and_reverify!
    get "/system-admin"
    assert_response :success

    # Travel past the reverification timeout (1 hour) but within
    # the session idle timeout (2 hours) so the session stays active.
    travel 90.minutes do
      get "/system-admin"
      assert_redirected_to "/reverify"
    end
  end

  test "skips reverification for API token requests" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )

    get "/system-admin", headers: {
      "Authorization" => "Bearer #{token.plaintext_token}",
      "Accept" => "application/json",
    }
    # Should not redirect to /reverify
    refute_equal "/reverify", URI.parse(response.location || "").path,
      "API token request should not be redirected to /reverify"
  end

  test "redirects to 2FA setup when user has no 2FA enabled" do
    @identity.disable_otp!
    sign_in_as(@user, tenant: @tenant)
    get "/system-admin"
    assert_redirected_to two_factor_setup_path
    assert_match(/two-factor/i, flash[:alert])
  end

  test "respects custom timeout from env var" do
    original = ENV["REVERIFICATION_TIMEOUT"]
    ENV["REVERIFICATION_TIMEOUT"] = "60"

    sign_in_and_reverify!
    get "/system-admin"
    assert_response :success

    travel 2.minutes do
      get "/system-admin"
      assert_redirected_to "/reverify"
    end
  ensure
    if original.nil?
      ENV.delete("REVERIFICATION_TIMEOUT")
    else
      ENV["REVERIFICATION_TIMEOUT"] = original
    end
  end

  test "stores return URL and redirects back after reverification" do
    sign_in_as(@user, tenant: @tenant)
    get "/system-admin/agent-runner"
    assert_redirected_to "/reverify"

    totp = ROTP::TOTP.new(@identity.otp_secret)
    post "/reverify", params: { code: totp.now }
    assert_redirected_to "http://#{@tenant.subdomain}.#{ENV["HOSTNAME"]}/system-admin/agent-runner"
  end
end
