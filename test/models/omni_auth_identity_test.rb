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
