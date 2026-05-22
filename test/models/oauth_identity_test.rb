require "test_helper"

class OauthIdentityTest < ActiveSupport::TestCase
  # Helper: minimal OmniAuth::AuthHash-like double sufficient for find_or_create_from_auth
  def fake_auth(provider: "github", uid: "u#{SecureRandom.hex(4)}",
                email: "oauth-#{SecureRandom.hex(4)}@example.com",
                name: "OAuth User", image: nil, nickname: nil)
    info = OpenStruct.new(email: email, name: name, image: image, nickname: nickname,
                          urls: OpenStruct.new(GitHub: "https://github.com/#{nickname}"))
    OpenStruct.new(provider: provider, uid: uid, info: info)
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
end
