require "test_helper"

class OmniAuthIdentityTest < ActiveSupport::TestCase
  # === Password Validation Tests ===

  test "password must be at least 14 characters" do
    identity = OmniAuthIdentity.new(
      email: "test@example.com",
      name: "Test User",
      password: "short",
      password_confirmation: "short",
    )
    assert_not identity.valid?
    assert identity.errors[:password].any?
  end

  test "password of 14 characters is valid" do
    identity = OmniAuthIdentity.new(
      email: "test@example.com",
      name: "Test User",
      password: "exactlyfourteen",
      password_confirmation: "exactlyfourteen",
    )
    assert identity.valid?, "Expected identity to be valid but got errors: #{identity.errors.full_messages}"
  end

  # === Common Password Validation Tests ===

  test "common password from rockyou list is rejected" do
    # "manchesterunited" is in the common passwords list
    identity = OmniAuthIdentity.new(
      email: "test@example.com",
      name: "Test User",
      password: "manchesterunited",
      password_confirmation: "manchesterunited",
    )
    assert_not identity.valid?
    assert_includes identity.errors[:password], "is too common. Please choose a more unique password."
  end

  test "common password check is case insensitive" do
    # Should reject regardless of case
    identity = OmniAuthIdentity.new(
      email: "test@example.com",
      name: "Test User",
      password: "MANCHESTERUNITED",
      password_confirmation: "MANCHESTERUNITED",
    )
    assert_not identity.valid?
    assert_includes identity.errors[:password], "is too common. Please choose a more unique password."
  end

  test "pattern-based common password is rejected" do
    # "passwordpassword" is in the common passwords list
    identity = OmniAuthIdentity.new(
      email: "test@example.com",
      name: "Test User",
      password: "passwordpassword",
      password_confirmation: "passwordpassword",
    )
    assert_not identity.valid?
    assert_includes identity.errors[:password], "is too common. Please choose a more unique password."
  end

  test "unique password is accepted" do
    identity = OmniAuthIdentity.new(
      email: "test@example.com",
      name: "Test User",
      password: "myuniquepassword123xyz",
      password_confirmation: "myuniquepassword123xyz",
    )
    assert identity.valid?, "Expected identity to be valid but got errors: #{identity.errors.full_messages}"
  end

  test "common password check does not run on existing records without password change" do
    # Create a valid identity first
    user = create_user(email: "existing@example.com", name: "Existing User")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "existing@example.com",
      name: "Existing User",
      password: "myuniquepassword123",
      password_confirmation: "myuniquepassword123",
    )

    # Update a non-password field - should not trigger password validation
    identity.name = "Updated Name"
    assert identity.valid?, "Expected identity to be valid when only updating name"
  end

  # === TOTP Code Reuse Tests ===

  test "TOTP code cannot be reused after successful verification" do
    user = create_user(email: "totp-reuse@example.com", name: "TOTP Reuse Test")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "totp-reuse@example.com",
      name: "TOTP Reuse Test",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    identity.generate_otp_secret!
    identity.enable_otp!

    totp = ROTP::TOTP.new(identity.otp_secret)
    code = totp.now

    # First use should succeed
    assert identity.verify_otp(code), "First use of TOTP code should succeed"

    # Same code should be rejected on replay
    identity.reload
    assert_not identity.verify_otp(code), "Replayed TOTP code should be rejected"
  end

  # === Dev-only TOTP bypass ===

  test "verify_otp accepts the configured bypass code in development environment when ENV is set" do
    user = create_user(email: "devbypass-#{SecureRandom.hex(4)}@example.com", name: "Dev Bypass")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "devbypass-#{SecureRandom.hex(4)}@example.com",
      name: "Dev Bypass",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    identity.generate_otp_secret!

    with_env("DEV_2FA_BYPASS_CODE" => "test-bypass-#{SecureRandom.hex(4)}") do |code|
      Rails.stub :env, ActiveSupport::StringInquirer.new("development") do
        assert identity.verify_otp(code),
               "expected the dev bypass code to be accepted in development when ENV is set"
        assert_not identity.verify_otp("999999"),
                   "non-matching codes must still be rejected"
      end
    end
  end

  test "verify_otp rejects the bypass code in development when ENV is unset" do
    user = create_user(email: "noenv-#{SecureRandom.hex(4)}@example.com", name: "No Env")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "noenv-#{SecureRandom.hex(4)}@example.com",
      name: "No Env",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    identity.generate_otp_secret!

    # Ensure env var is NOT set even in development
    with_env("DEV_2FA_BYPASS_CODE" => nil) do
      Rails.stub :env, ActiveSupport::StringInquirer.new("development") do
        assert_not identity.verify_otp("111111"),
                   "with no env var set, no code should bypass"
        assert_not identity.verify_otp(""),
                   "empty string must not bypass either"
      end
    end
  end

  test "verify_otp rejects the bypass code outside development environment even when ENV is set" do
    user = create_user(email: "nobypass-#{SecureRandom.hex(4)}@example.com", name: "No Bypass")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "nobypass-#{SecureRandom.hex(4)}@example.com",
      name: "No Bypass",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    identity.generate_otp_secret!

    with_env("DEV_2FA_BYPASS_CODE" => "configured") do |code|
      # Default test environment — bypass must NOT fire even when env is set
      assert_not identity.verify_otp(code),
                 "dev bypass must NOT be accepted outside development, even with env set"

      Rails.stub :env, ActiveSupport::StringInquirer.new("production") do
        assert_not identity.verify_otp(code),
                   "dev bypass must NOT be accepted in production, even with env set"
      end
    end
  end

  test "verify_otp dev bypass does NOT bypass otp_locked? lockout" do
    user = create_user(email: "lockbypass-#{SecureRandom.hex(4)}@example.com", name: "Locked")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "lockbypass-#{SecureRandom.hex(4)}@example.com",
      name: "Locked",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    identity.generate_otp_secret!
    # Force the lockout state
    identity.update_columns(
      otp_failed_attempts: OmniAuthIdentity::MAX_OTP_ATTEMPTS,
      otp_locked_until: 1.hour.from_now,
    )

    with_env("DEV_2FA_BYPASS_CODE" => "anycode") do |code|
      Rails.stub :env, ActiveSupport::StringInquirer.new("development") do
        assert_not identity.verify_otp(code),
                   "dev bypass should not override a real lockout"
      end
    end
  end

  # Stub env vars for the block, then restore the prior value(s).
  # Yields the value of the LAST key in the hash for convenience when there's only one.
  def with_env(env_vars)
    original = env_vars.keys.to_h { |k| [k, ENV[k]] }
    env_vars.each { |k, v| ENV[k] = v }
    yield env_vars.values.last
  ensure
    original.each { |k, v| ENV[k] = v }
  end

  # === Password Reset Token Tests ===

  test "generate_reset_password_token! returns raw token and stores hash" do
    user = create_user(email: "reset@example.com", name: "Reset User")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "reset@example.com",
      name: "Reset User",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )

    raw_token = identity.generate_reset_password_token!

    # Raw token should be returned
    assert raw_token.present?
    assert_equal 43, raw_token.length # urlsafe_base64(32) produces 43 chars

    # Stored token should be SHA256 hash (64 hex chars)
    assert identity.reset_password_token.present?
    assert_equal 64, identity.reset_password_token.length
    assert_not_equal raw_token, identity.reset_password_token

    # Stored token should be hash of raw token
    assert_equal Digest::SHA256.hexdigest(raw_token), identity.reset_password_token
  end

  test "find_by_reset_password_token finds identity with valid raw token" do
    user = create_user(email: "findme@example.com", name: "Find Me")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "findme@example.com",
      name: "Find Me",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )

    raw_token = identity.generate_reset_password_token!

    found = OmniAuthIdentity.find_by_reset_password_token(raw_token)
    assert_equal identity.id, found.id
  end

  test "find_by_reset_password_token returns nil for invalid token" do
    found = OmniAuthIdentity.find_by_reset_password_token("invalidtoken123")
    assert_nil found
  end

  test "find_by_reset_password_token returns nil for blank token" do
    assert_nil OmniAuthIdentity.find_by_reset_password_token("")
    assert_nil OmniAuthIdentity.find_by_reset_password_token(nil)
  end

  test "reset_password_token_valid? returns true within 2 hours" do
    user = create_user(email: "valid@example.com", name: "Valid Token")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "valid@example.com",
      name: "Valid Token",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )

    identity.generate_reset_password_token!
    assert identity.reset_password_token_valid?
  end

  test "reset_password_token_valid? returns false after 2 hours" do
    user = create_user(email: "expired@example.com", name: "Expired Token")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "expired@example.com",
      name: "Expired Token",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )

    identity.generate_reset_password_token!
    identity.update!(reset_password_sent_at: 3.hours.ago)

    assert_not identity.reset_password_token_valid?
  end

  test "update_password! clears reset token" do
    user = create_user(email: "update@example.com", name: "Update Password")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: "update@example.com",
      name: "Update Password",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )

    identity.generate_reset_password_token!
    assert identity.reset_password_token.present?

    identity.update_password!("newvalidpassword123")

    assert_nil identity.reset_password_token
    assert_nil identity.reset_password_sent_at
  end

  # === Email Confirmation Tests ===

  test "email_verified? returns false when email_confirmed_at is nil" do
    identity = OmniAuthIdentity.new(email_confirmed_at: nil)
    assert_not identity.email_verified?
  end

  test "email_verified? returns true when email_confirmed_at is set" do
    identity = OmniAuthIdentity.new(email_confirmed_at: Time.current)
    assert identity.email_verified?
  end

  test "send_email_confirmation! returns raw token and stores hash" do
    user = create_user(email: "confirm-#{SecureRandom.hex(4)}@example.com", name: "Confirm Send")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: user.email,
      name: user.name,
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )

    raw_token = identity.send_email_confirmation!

    assert raw_token.present?
    assert_equal 43, raw_token.length # urlsafe_base64(32)
    assert identity.email_confirmation_token.present?
    assert_equal 64, identity.email_confirmation_token.length # SHA256 hex
    assert_not_equal raw_token, identity.email_confirmation_token
    assert_equal Digest::SHA256.hexdigest(raw_token), identity.email_confirmation_token
    assert identity.email_confirmation_sent_at.present?
  end

  test "find_by_email_confirmation_token returns the identity for a valid raw token" do
    user = create_user(email: "findc-#{SecureRandom.hex(4)}@example.com", name: "Find Confirm")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: user.email,
      name: user.name,
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    raw = identity.send_email_confirmation!

    assert_equal identity.id, OmniAuthIdentity.find_by_email_confirmation_token(raw).id
  end

  test "find_by_email_confirmation_token returns nil for blank or invalid tokens" do
    assert_nil OmniAuthIdentity.find_by_email_confirmation_token(nil)
    assert_nil OmniAuthIdentity.find_by_email_confirmation_token("")
    assert_nil OmniAuthIdentity.find_by_email_confirmation_token("not-a-real-token")
  end

  test "confirm_email! flips email_confirmed_at and clears the token" do
    user = create_user(email: "flip-#{SecureRandom.hex(4)}@example.com", name: "Flip Confirm")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: user.email,
      name: user.name,
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    raw = identity.send_email_confirmation!

    assert_not identity.email_verified?
    assert identity.confirm_email!(raw)
    identity.reload
    assert identity.email_verified?
    assert_nil identity.email_confirmation_token
    assert_nil identity.email_confirmation_sent_at
  end

  test "confirm_email! returns false for a token that doesn't match" do
    user = create_user(email: "bad-#{SecureRandom.hex(4)}@example.com", name: "Bad Token")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: user.email,
      name: user.name,
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    identity.send_email_confirmation!

    assert_not identity.confirm_email!("wrong-token-value")
    assert_not identity.reload.email_verified?
  end

  test "confirm_email! is idempotent — second call returns true and leaves verified" do
    # Once verified, calling confirm_email! again with any token is a no-op success
    # so re-clicked email links don't confuse the user with errors.
    user = create_user(email: "idemp-#{SecureRandom.hex(4)}@example.com", name: "Idemp Confirm")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: user.email,
      name: user.name,
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    raw = identity.send_email_confirmation!
    assert identity.confirm_email!(raw)
    assert identity.confirm_email!(raw)
    assert identity.reload.email_verified?
  end

  test "confirm_email! rejects tokens older than the validity window" do
    user = create_user(email: "stale-#{SecureRandom.hex(4)}@example.com", name: "Stale Token")
    identity = OmniAuthIdentity.create!(
      user: user,
      email: user.email,
      name: user.name,
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    raw = identity.send_email_confirmation!
    # Force the sent_at into the past beyond the window
    identity.update_columns(email_confirmation_sent_at: 8.days.ago)

    assert_not identity.confirm_email!(raw)
    assert_not identity.reload.email_verified?
  end

  # === User Association Tests ===

  test "belongs_to user" do
    user = create_user(email: "assoc-test@example.com", name: "Assoc Test")
    identity = user.find_or_create_omni_auth_identity!

    assert_equal user.id, identity.user_id
    assert_equal user, identity.user
  end

  test "user has_one omni_auth_identity" do
    user = create_user(email: "has-one-test@example.com", name: "HasOne Test")
    identity = user.find_or_create_omni_auth_identity!

    assert_equal identity, user.omni_auth_identity
  end

  test "find_or_create_omni_auth_identity sets user_id on new record" do
    user = create_user(email: "new-oaid@example.com", name: "New OAID")
    assert_nil user.omni_auth_identity

    identity = user.find_or_create_omni_auth_identity!

    assert_equal user.id, identity.user_id
    assert_equal user.email, identity.email
  end

  test "find_or_create_omni_auth_identity adopts orphaned record from registration" do
    # Simulates the OmniAuth identity registration flow: the gem creates
    # an OmniAuthIdentity (no user_id) before a User exists. When the
    # callback creates the User and calls find_or_create_omni_auth_identity!,
    # it should adopt the existing record rather than creating a duplicate.
    user = create_user(email: "adopt-test@example.com", name: "Adopt Test")
    orphan = OmniAuthIdentity.create!(
      email: "adopt-test@example.com",
      name: "Adopt Test",
      password: "securepassword123",
      password_confirmation: "securepassword123",
    )
    assert_nil orphan.user_id

    adopted = user.find_or_create_omni_auth_identity!

    assert_equal orphan.id, adopted.id
    assert_equal user.id, adopted.user_id
  end

  test "find_or_create_omni_auth_identity returns existing record" do
    user = create_user(email: "existing-oaid@example.com", name: "Existing OAID")
    first = user.find_or_create_omni_auth_identity!
    second = user.find_or_create_omni_auth_identity!

    assert_equal first.id, second.id
  end
end
