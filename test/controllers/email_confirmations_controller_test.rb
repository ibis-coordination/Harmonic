require "test_helper"

class EmailConfirmationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "ec-test-#{SecureRandom.hex(4)}", name: "EC Test")
    @host = create_user(email: "ec-host-#{SecureRandom.hex(4)}@example.com", name: "EC Host")
    @tenant.add_user!(@host)
    @tenant.create_main_collective!(created_by: @host)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def make_identity_with_token
    user = create_user(email: "tok-#{SecureRandom.hex(4)}@example.com", name: "Token Owner")
    @tenant.add_user!(user)
    identity = OmniAuthIdentity.create!(
      user: user, email: user.email, name: user.name,
      password: "validpassword123", password_confirmation: "validpassword123",
    )
    raw = identity.send_email_confirmation!
    [identity, raw]
  end

  test "GET /confirm-email/:token marks the identity verified and renders a confirmation" do
    identity, raw = make_identity_with_token
    assert_not identity.email_verified?

    get "/confirm-email/#{raw}"

    assert_response :success
    identity.reload
    assert identity.email_verified?
  end

  test "GET /confirm-email/:token with an unknown token renders a not-found page" do
    get "/confirm-email/totally-not-a-real-token"
    assert_response :not_found
  end

  test "GET /confirm-email/:token works without any authenticated session" do
    # Confirmation links must be usable when the user is logged out — the link
    # is the proof-of-email-ownership; we don't want to gate it behind login.
    identity, raw = make_identity_with_token
    # No session — make sure the auth/billing/activation gates are exempt.
    get "/confirm-email/#{raw}"
    assert_response :success
    assert identity.reload.email_verified?
  end

  test "GET /confirm-email/:token is idempotent — a second click is fine" do
    identity, raw = make_identity_with_token
    get "/confirm-email/#{raw}"
    assert_response :success
    # After confirmation, the stored hash is cleared. A second click should
    # still 200 (already-verified short-circuit), not 404 or 500.
    get "/confirm-email/#{raw}"
    assert_response :success
  end

  test "GET /confirm-email/:token shows an expired-link page when the token is past its window" do
    identity, raw = make_identity_with_token
    # Force the sent_at into the past beyond the validity window
    identity.update_columns(email_confirmation_sent_at: 8.days.ago)

    get "/confirm-email/#{raw}"
    assert_response :unprocessable_entity
    assert_match(/expired/i, response.body)
    assert_not identity.reload.email_verified?
  end

  test "GET /confirm-email/:token clears session[:activation_return_to] so the user isn't bounced to a stale URL afterwards" do
    # Reproduce the bug: log in as a partially-activated user, trigger the
    # activation gate against a path that stashes itself, then confirm email
    # via the link. The stash must be gone so the next /activate visit
    # doesn't redirect back to the gated page.
    user = create_user(email: "stash-#{SecureRandom.hex(4)}@example.com", name: "Stashy")
    @tenant.add_user!(user)
    identity = OmniAuthIdentity.create!(
      user: user, email: user.email, name: user.name,
      password: "validpassword123", password_confirmation: "validpassword123",
    )
    # 2FA enabled but email NOT verified → gate fires for the email branch
    identity.generate_otp_secret!
    identity.enable_otp!
    sign_in_as(user, tenant: @tenant, activate: false)
    # Make a request that triggers the gate so :activation_return_to gets stashed.
    get "/u/#{user.handle}/settings/tokens/finalize"
    assert_equal "/u/#{user.handle}/settings/tokens/finalize", session[:activation_return_to],
                 "sanity: gate should have stashed the URL"

    raw = identity.send_email_confirmation!
    get "/confirm-email/#{raw}"

    assert_nil session[:activation_return_to],
               "expected the email-confirmation handler to clear the stale activation_return_to so it doesn't dictate the next /activate redirect"
  end
end
