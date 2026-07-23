require "test_helper"
require "vips"

# Controller-level coverage of the GitHub OAuth callback — signup, re-login,
# account linking by email, per-tenant provider enforcement, avatar fetch,
# and the 2FA challenge. Uses OmniAuth test mode: the middleware intercepts
# /auth/github/callback and injects the mock auth hash, so the full
# SessionsController#oauth_callback path runs without a real provider.
class OauthSignupFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @tenant = create_tenant(subdomain: "oauth-#{SecureRandom.hex(4)}", name: "OAuth Tenant")
    OmniAuth.config.test_mode = true
  end

  def teardown
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  def github_auth(email:, name: "Octo Tester", uid: SecureRandom.hex(6), image: nil)
    OmniAuth::AuthHash.new(
      provider: "github",
      uid: uid,
      info: {
        email: email,
        name: name,
        nickname: "octo-#{uid}",
        image: image,
        urls: { "GitHub" => "https://github.com/octo-#{uid}" },
      }
    )
  end

  def github_callback(auth, tenant: @tenant)
    OmniAuth.config.mock_auth[:github] = auth
    host! "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"
    cookies[:redirect_to_subdomain] = tenant.subdomain
    get "/auth/github/callback"
  end

  # === New-user signup ===

  test "GitHub callback signs up a brand-new user with a verified email and no confirmation email" do
    email = "newgh-#{SecureRandom.hex(4)}@example.com"

    assert_difference "User.count", 1 do
      assert_no_enqueued_emails do
        github_callback(github_auth(email: email))
      end
    end

    assert_redirected_to "/login/return"
    user = User.find_by(email: email)
    assert_not_nil user
    assert_equal user.id, session[:user_id], "expected a signed-in session after callback"
    assert user.email_verified?,
           "GitHub-attested emails are trusted; no confirmation round-trip required"
    assert_equal 1, user.oauth_identities.where(provider: "github").count
    assert_not_nil user.omni_auth_identity,
                   "every user needs an OmniAuthIdentity so the email can't be claimed by a later signup"
  end

  test "GitHub callback for a returning user reuses the account" do
    email = "returning-#{SecureRandom.hex(4)}@example.com"
    auth = github_auth(email: email)
    github_callback(auth)
    first_user_id = session[:user_id]

    assert_no_difference "User.count" do
      github_callback(auth)
    end

    assert_redirected_to "/login/return"
    assert_equal first_user_id, session[:user_id], "expected the same account on re-login"
  end

  # === Account linking by email ===

  test "GitHub login with a matching email links to the existing email/password account" do
    user = create_user(email: "linkme-#{SecureRandom.hex(4)}@example.com", name: "Link Me")
    user.find_or_create_omni_auth_identity!

    assert_no_difference "User.count" do
      github_callback(github_auth(email: user.email))
    end

    identity = OauthIdentity.find_by(provider: "github", user: user)
    assert_not_nil identity, "expected the GitHub identity linked to the existing user"
    assert_equal user.id, session[:user_id]
  end

  test "GitHub link verifies a previously unconfirmed email/password account's email" do
    user = create_user(email: "unconf-#{SecureRandom.hex(4)}@example.com", name: "Unconfirmed")
    omni = user.find_or_create_omni_auth_identity!
    assert_nil omni.email_confirmed_at

    github_callback(github_auth(email: user.email))

    assert_not_nil omni.reload.email_confirmed_at,
                   "GitHub attests the email, so the pending confirmation is satisfied"
  end

  # === Per-tenant provider enforcement ===

  test "callback renders 403 when the provider is not enabled for the tenant" do
    @tenant.auth_providers = ["identity"]
    @tenant.save!

    assert_no_difference "User.count" do
      github_callback(github_auth(email: "blocked-#{SecureRandom.hex(4)}@example.com"))
    end

    assert_response :forbidden
    assert_match(/github.*not enabled/i, response.body)
    assert_nil session[:user_id]
  end

  # === Avatar fetch (regression: OAuth signup avatar IOError) ===

  test "GitHub avatar is fetched and attached on signup" do
    avatar_url = "https://avatars.example.com/u/42.png"
    png = Vips::Image.black(64, 64) + [128, 64, 200]
    png_bytes = png.write_to_buffer(".png")
    WebMock.stub_request(:get, avatar_url)
      .to_return(status: 200, body: png_bytes, headers: { "Content-Type" => "image/png" })

    email = "avatar-#{SecureRandom.hex(4)}@example.com"
    # image_url= resolves the host before fetching (SSRF guard); stub DNS to a
    # public address so the WebMock-stubbed fetch is reached deterministically.
    Resolv.stub(:getaddresses, ["140.82.112.3"]) do
      github_callback(github_auth(email: email, image: avatar_url))
    end

    assert_redirected_to "/login/return"
    user = User.find_by(email: email)
    assert user.image.attached?, "expected the GitHub avatar attached during signup"
  end

  # === Second factor at login ===

  test "GitHub login with TOTP enabled is challenged for the second factor" do
    user = create_user(email: "ghotp-#{SecureRandom.hex(4)}@example.com", name: "GH OTP")
    omni = user.find_or_create_omni_auth_identity!
    omni.generate_otp_secret!
    omni.enable_otp!

    github_callback(github_auth(email: user.email))

    assert_redirected_to "/login/verify-2fa"
    assert_equal omni.id, session[:pending_2fa_identity_id]
    assert_nil session[:user_id],
               "the session must not be established before the second factor is verified"
  end

  test "completing the TOTP challenge after GitHub login establishes the session and audit-logs the login" do
    user = create_user(email: "ghotp2-#{SecureRandom.hex(4)}@example.com", name: "GH OTP Done")
    omni = user.find_or_create_omni_auth_identity!
    omni.generate_otp_secret!
    omni.enable_otp!
    github_callback(github_auth(email: user.email))

    log_file = Rails.root.join("log/security_audit.log")
    offset = File.exist?(log_file) ? File.readlines(log_file).size : 0
    totp = ROTP::TOTP.new(omni.otp_secret)
    post "/login/verify-2fa", params: { code: totp.now }

    assert_redirected_to "/login/return"
    assert_equal user.id, session[:user_id]
    entries = File.readlines(log_file).drop(offset).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
    success = entries.find { |e| e["event"] == "login_success" && e["user_id"] == user.id }
    refute_nil success,
               "2FA-protected logins must appear in the login-success audit trail like non-2FA logins do"
  end

  test "TOTP challenge completion resolves the user via the identity record, not an email string match" do
    # The OmniAuthIdentity knows its user directly; completion must not
    # depend on User.email matching OmniAuthIdentity.email (legacy rows and
    # manual corrections can diverge).
    user = create_user(email: "ghdiverge-#{SecureRandom.hex(4)}@example.com", name: "GH Diverged")
    omni = user.find_or_create_omni_auth_identity!
    omni.generate_otp_secret!
    omni.enable_otp!
    github_callback(github_auth(email: user.email))
    # Simulate a legacy/diverged row: the identity's email no longer matches
    # any User.email.
    omni.update_column(:email, "diverged-#{SecureRandom.hex(4)}@example.com")

    totp = ROTP::TOTP.new(omni.otp_secret)
    post "/login/verify-2fa", params: { code: totp.now }

    assert_redirected_to "/login/return"
    assert_equal user.id, session[:user_id],
                 "completion must resolve through identity.user, not break on email divergence"
  end

  test "GitHub login without TOTP enabled is not challenged" do
    email = "ghnootp-#{SecureRandom.hex(4)}@example.com"

    github_callback(github_auth(email: email))

    assert_redirected_to "/login/return"
    assert_not_nil session[:user_id]
  end

  test "a pending-2FA login cannot reach protected content by skipping the challenge" do
    # Redteam: after the provider callback but before the TOTP code, the user
    # is in the pending-2FA state (pending_2fa_identity_id set, user_id NOT).
    # Navigating away from /login/verify-2fa to a protected tenant page must
    # not serve it — the second factor cannot be skipped.
    user = create_user(email: "ghskip-#{SecureRandom.hex(4)}@example.com", name: "GH Skip")
    @tenant.add_user!(user)
    @tenant.create_main_collective!(created_by: user)
    omni = user.find_or_create_omni_auth_identity!
    omni.generate_otp_secret!
    omni.enable_otp!
    github_callback(github_auth(email: user.email))
    assert_equal omni.id, session[:pending_2fa_identity_id]
    assert_nil session[:user_id], "no session yet — the challenge is unanswered"

    # Skip the challenge and hit a protected tenant page.
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/"

    assert_nil session[:user_id], "the second factor was never completed — still no session"
    assert_redirected_to "/login"
  end
end
