# typed: false
require "test_helper"

# Bot protection for the two OmniAuth-handled POSTs that can't go through the
# BotProtection controller concern (because OmniAuth middleware consumes them
# before any Rails controller runs):
#
#   POST /auth/identity/register
#   POST /auth/identity/callback
#
# We verify the middleware redirects bot-flagged submissions away from
# OmniAuth and that legitimate (empty-honeypot) submissions still reach the
# downstream stack.
class OmniAuthBotProtectionTest < ActionDispatch::IntegrationTest
  setup do
    @original_force = ENV["FORCE_BOT_PROTECTION_IN_TEST"]
    @original_turnstile = ENV["TURNSTILE_SECRET_KEY"]
    ENV["FORCE_BOT_PROTECTION_IN_TEST"] = "1"
    # Isolate from the dev container's ambient TURNSTILE_SECRET_KEY so the
    # base honeypot tests don't accidentally try to call Cloudflare.
    ENV.delete("TURNSTILE_SECRET_KEY")
    host! "auth.#{ENV.fetch("HOSTNAME", nil)}"
  end

  teardown do
    if @original_force.nil?
      ENV.delete("FORCE_BOT_PROTECTION_IN_TEST")
    else
      ENV["FORCE_BOT_PROTECTION_IN_TEST"] = @original_force
    end
    if @original_turnstile.nil?
      ENV.delete("TURNSTILE_SECRET_KEY")
    else
      ENV["TURNSTILE_SECRET_KEY"] = @original_turnstile
    end
  end

  test "POST /auth/identity/register with filled honeypot does NOT create an OmniAuthIdentity" do
    before = OmniAuthIdentity.count
    post "/auth/identity/register", params: {
      email: "spam-#{SecureRandom.hex(4)}@example.com",
      name: "Spam Bot",
      password: "longenoughpassword1",
      password_confirmation: "longenoughpassword1",
      company_website: "filled-by-bot",
    }
    assert_response :redirect
    assert_equal before, OmniAuthIdentity.count, "honeypot must short-circuit before OmniAuth creates an identity"
  end

  test "POST /auth/identity/callback with filled honeypot does NOT establish a session" do
    post "/auth/identity/callback", params: {
      auth_key: "anyone@example.com",
      password: "anything-at-all",
      company_website: "spam",
    }
    assert_response :redirect
    # No session was set
    assert_nil session[:user_id], "honeypot must short-circuit before OmniAuth touches sessions"
  end

  test "with Turnstile enabled and verification failing, register is blocked" do
    ENV["TURNSTILE_SECRET_KEY"] = "test-secret"
    WebMock.stub_request(:post, "https://challenges.cloudflare.com/turnstile/v0/siteverify")
      .to_return(status: 200, body: '{"success":false}')

    before = OmniAuthIdentity.count
    post "/auth/identity/register", params: {
      email: "ok-#{SecureRandom.hex(4)}@example.com",
      name: "OK",
      password: "longenoughpassword1",
      password_confirmation: "longenoughpassword1",
      cf_turnstile_response: "bad",
    }
    assert_response :redirect
    assert_equal before, OmniAuthIdentity.count
  end

  test "with empty honeypot and Turnstile disabled, the middleware passes through to OmniAuth" do
    # Confirm the middleware doesn't accidentally trip on legitimate submissions.
    # We can prove this without exercising the full downstream stack by
    # asserting the middleware never sets its "could not be processed" flash.
    #
    # We can't safely POST /auth/identity/callback in test mode (downstream
    # SessionsController#oauth_callback needs current_tenant, which is not
    # set on the bare AUTH_SUBDOMAIN host) — but the unit-level signal we
    # care about is whether the middleware short-circuits. We test that
    # directly against the middleware's #call.
    middleware = OmniAuthBotProtection.new(->(_env) { [200, {}, ["ok"]] })
    env = Rack::MockRequest.env_for("/auth/identity/callback",
                                    method: "POST",
                                    params: { "auth_key" => "x", "password" => "y" })
    env["rack.session"] = {}
    status, _headers, body = middleware.call(env)
    assert_equal 200, status
    assert_equal ["ok"], body
  end
end
