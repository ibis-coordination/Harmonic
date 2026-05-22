require "test_helper"

class OauthIdentityTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  # Helper: minimal OmniAuth::AuthHash-like double sufficient for find_or_create_from_auth
  def fake_auth(provider: "github", uid: "u#{SecureRandom.hex(4)}",
                email: "oauth-#{SecureRandom.hex(4)}@example.com",
                name: "OAuth User", image: nil, nickname: nil)
    info = OpenStruct.new(email: email, name: name, image: image, nickname: nickname,
                          urls: OpenStruct.new(GitHub: "https://github.com/#{nickname}"))
    OpenStruct.new(provider: provider, uid: uid, info: info)
  end

  def some_tenant
    Tenant.find_by(subdomain: ENV["PRIMARY_SUBDOMAIN"]) ||
      Tenant.create!(subdomain: ENV["PRIMARY_SUBDOMAIN"], name: "Primary")
  end

  test "find_or_create_from_auth marks the linked OmniAuthIdentity as email-verified" do
    # Trust the OAuth provider's verified-email claim (Google/GitHub assert ownership).
    # Email/password-only identities have to confirm via the activation flow.
    identity = OauthIdentity.find_or_create_from_auth(fake_auth)

    omni = identity.user.omni_auth_identity
    assert omni.present?, "expected a linked OmniAuthIdentity"
    assert omni.email_verified?,
           "expected email to be auto-verified after OAuth sign-in"
    assert omni.email_confirmed_at.present?
  end

  test "find_or_create_from_auth does NOT mark email-verified for provider='identity' (email/password)" do
    # The OmniAuth Identity gem uses provider="identity" for email/password
    # signups, which do NOT verify the email. Those users must complete the
    # /confirm-email round-trip. Regression for the bug where a new email/
    # password signup landed on /activate with the email item already ✓.
    identity = OauthIdentity.find_or_create_from_auth(fake_auth(provider: "identity"))
    omni = identity.user.omni_auth_identity
    assert_nil omni.email_confirmed_at,
               "expected email/password ('identity' provider) to leave email unverified"
    assert_not omni.email_verified?
  end

  test "find_or_create_from_auth does NOT overwrite an existing email_confirmed_at" do
    # A second OAuth round-trip shouldn't bump the timestamp — the original
    # confirmation moment is the meaningful one.
    auth = fake_auth
    OauthIdentity.find_or_create_from_auth(auth)
    user = User.find_by(email: auth.info.email)
    original_at = user.omni_auth_identity.email_confirmed_at
    # Advance time deliberately so we'd see drift if we overwrote
    travel_to(2.hours.from_now) do
      OauthIdentity.find_or_create_from_auth(auth)
    end
    assert_equal original_at.to_i, user.reload.omni_auth_identity.email_confirmed_at.to_i
  end

  # === Auto-send confirmation email on identity-provider signup ===
  # The email is sent exactly once, at signup. Subsequent logins don't trigger
  # another send — the user has to click the resend button on /activate.

  test "find_or_create_from_auth enqueues the confirmation email on identity-provider signup" do
    tenant = some_tenant
    auth = fake_auth(provider: "identity")

    assert_enqueued_emails 1 do
      OauthIdentity.find_or_create_from_auth(auth, tenant: tenant)
    end

    omni = User.find_by(email: auth.info.email).omni_auth_identity
    assert omni.email_confirmation_token.present?,
           "expected a confirmation token to be generated during the signup send"
  end

  test "find_or_create_from_auth does NOT enqueue another email on subsequent identity-provider login" do
    tenant = some_tenant
    auth = fake_auth(provider: "identity")
    # Signup — sends once.
    OauthIdentity.find_or_create_from_auth(auth, tenant: tenant)

    # Login again with the same auth — must NOT send a second email.
    assert_enqueued_emails 0 do
      OauthIdentity.find_or_create_from_auth(auth, tenant: tenant)
    end
  end

  test "find_or_create_from_auth does NOT enqueue a confirmation email for third-party OAuth signups" do
    # GitHub/Google asserts the email, so the user is auto-verified — no need
    # to send a confirmation email even on fresh signup.
    tenant = some_tenant

    assert_enqueued_emails 0 do
      OauthIdentity.find_or_create_from_auth(fake_auth(provider: "github"), tenant: tenant)
    end
  end

  test "find_or_create_from_auth does NOT enqueue an email when no tenant is provided" do
    # The mailer needs the tenant for the subdomain in the confirmation URL.
    # Without it, refuse to send rather than email a broken link.
    auth = fake_auth(provider: "identity")

    assert_enqueued_emails 0 do
      OauthIdentity.find_or_create_from_auth(auth)
    end
  end
end
