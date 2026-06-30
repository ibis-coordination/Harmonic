require "test_helper"

class RefreshTokenTest < ActiveSupport::TestCase
  setup do
    @user = create_user
  end

  # === Issuance ===

  test "issue! creates a row with required fields and returns plaintext" do
    token = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    assert_not_nil token.token_digest
    assert_equal 64, token.token_digest.length # SHA256 hex
    assert_not_nil token.family_id
    assert_not_nil token.expires_at
    assert_in_delta RefreshToken::LIFETIME.from_now.to_i, token.expires_at.to_i, 5
    assert_not_nil token.plaintext_token
  end

  test "plaintext is recoverable only on the original instance" do
    token = RefreshToken.issue!(user: @user)
    reloaded = RefreshToken.find(token.id)
    assert_nil reloaded.plaintext_token
  end

  test "reload clears in-memory plaintext on the original instance" do
    token = RefreshToken.issue!(user: @user)
    assert_not_nil token.plaintext_token
    token.reload
    assert_nil token.plaintext_token
  end

  test "user_must_be_human only validates on create — existing tokens can be updated even if user_type would change" do
    token = RefreshToken.issue!(user: @user)
    # Simulate the user_type changing on the underlying user. We bypass the
    # User#human? check by stubbing on the in-memory instance.
    token.user.define_singleton_method(:human?) { false }
    # revoke! triggers update — must succeed despite stubbed non-human
    token.revoke!(reason: "user_logout")
    assert token.reload.revoked?
  end

  test "each issue! generates a unique digest" do
    digests = 5.times.map { RefreshToken.issue!(user: @user).token_digest }
    assert_equal 5, digests.uniq.length
  end

  test "issue! refuses non-human users" do
    _tenant, _collective, tenanted_user = create_tenant_collective_user
    agent = create_ai_agent(parent: tenanted_user)
    assert_raises(ActiveRecord::RecordInvalid) do
      RefreshToken.issue!(user: agent)
    end
  end

  test "issue! starts a new family per call" do
    a = RefreshToken.issue!(user: @user)
    b = RefreshToken.issue!(user: @user)
    assert_not_equal a.family_id, b.family_id
  end

  test "issue! records two_factor_at when provided, nil when not" do
    t = 2.hours.ago
    with_2fa = RefreshToken.issue!(user: @user, two_factor_at: t)
    no_2fa = RefreshToken.issue!(user: @user)
    assert_in_delta t.to_i, with_2fa.two_factor_at.to_i, 1
    assert_nil no_2fa.two_factor_at
  end

  test "issue! captures device label, user agent, and IP from request" do
    request = Struct.new(:user_agent, :remote_ip).new(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4) AppleWebKit",
      "203.0.113.5"
    )
    token = RefreshToken.issue!(user: @user, request: request)
    assert_equal "iPhone", token.device_label
    assert_equal "203.0.113.5", token.ip_at_issue
    assert_match(/iPhone/, T.must(token.user_agent))
  end

  # === Lookup ===

  test "find_by_plaintext returns the row for a valid token" do
    token = RefreshToken.issue!(user: @user)
    found = RefreshToken.find_by_plaintext(token.plaintext_token)
    assert_equal token.id, T.must(found).id
  end

  test "find_by_plaintext returns nil for blank or unknown tokens" do
    assert_nil RefreshToken.find_by_plaintext(nil)
    assert_nil RefreshToken.find_by_plaintext("")
    assert_nil RefreshToken.find_by_plaintext("not-a-real-token")
  end

  # === Predicates ===

  test "expired? reflects expires_at" do
    token = RefreshToken.issue!(user: @user)
    assert_not token.expired?
    token.update!(expires_at: 1.minute.ago)
    assert token.expired?
  end

  test "revoked? and revoked_reason are set by revoke!" do
    token = RefreshToken.issue!(user: @user)
    assert_not token.revoked?
    token.revoke!(reason: "user_logout")
    assert token.revoked?
    assert_equal "user_logout", token.revoked_reason
  end

  test "revoke! is idempotent" do
    token = RefreshToken.issue!(user: @user)
    token.revoke!(reason: "user_logout")
    original_time = token.revoked_at
    travel 1.minute do
      token.revoke!(reason: "admin")
    end
    assert_equal "user_logout", token.reload.revoked_reason
    assert_in_delta original_time.to_i, token.revoked_at.to_i, 1
  end

  test "rotated? reflects rotate!" do
    token = RefreshToken.issue!(user: @user)
    assert_not token.rotated?
    token.rotate!
    assert token.rotated?
  end

  test "active? requires non-revoked and non-expired" do
    token = RefreshToken.issue!(user: @user)
    assert token.active?
    token.revoke!(reason: "user_logout")
    assert_not token.active?
  end

  # === Rotation ===

  test "rotate! returns a successor in the same family with new digest" do
    token = RefreshToken.issue!(user: @user)
    successor = token.rotate!
    assert_equal token.family_id, successor.family_id
    assert_not_equal token.token_digest, successor.token_digest
    assert_not_nil successor.plaintext_token
  end

  test "rotate! carries two_factor_at forward to the successor" do
    t = 1.day.ago
    token = RefreshToken.issue!(user: @user, two_factor_at: t)
    successor = token.rotate!
    assert_in_delta t.to_i, T.must(successor.two_factor_at).to_i, 1
  end

  test "rotate! marks self rotated_at" do
    token = RefreshToken.issue!(user: @user)
    token.rotate!
    assert_not_nil token.rotated_at
  end

  test "rotate! cannot be called twice on the same token" do
    token = RefreshToken.issue!(user: @user)
    token.rotate!
    assert_raises(RefreshToken::AlreadyRotated) { token.rotate! }
  end

  test "rotate! refuses revoked tokens" do
    token = RefreshToken.issue!(user: @user)
    token.revoke!(reason: "user_logout")
    assert_raises(RefreshToken::NotRotatable) { token.rotate! }
  end

  test "rotate! refuses expired tokens" do
    token = RefreshToken.issue!(user: @user)
    token.update!(expires_at: 1.minute.ago)
    assert_raises(RefreshToken::NotRotatable) { token.rotate! }
  end

  # === Family revocation ===

  test "revoke_family! revokes every non-revoked token in the family" do
    a = RefreshToken.issue!(user: @user)
    b = a.rotate!
    RefreshToken.revoke_family!(a.family_id, reason: "rotation_replay")
    assert a.reload.revoked?
    assert b.reload.revoked?
    assert_equal "rotation_replay", a.reload.revoked_reason
    assert_equal "rotation_replay", b.reload.revoked_reason
  end

  test "revoke_family! does not affect tokens in other families" do
    a = RefreshToken.issue!(user: @user)
    other = RefreshToken.issue!(user: @user)
    RefreshToken.revoke_family!(a.family_id, reason: "rotation_replay")
    assert_not other.reload.revoked?
  end

  test "revoke_family! leaves already-revoked tokens untouched (no reason overwrite)" do
    a = RefreshToken.issue!(user: @user)
    a.revoke!(reason: "user_logout")
    RefreshToken.revoke_family!(a.family_id, reason: "rotation_replay")
    assert_equal "user_logout", a.reload.revoked_reason
  end

  # === Digest ===

  test "digest is deterministic SHA-256 hex" do
    raw = "known-test-value"
    assert_equal Digest::SHA256.hexdigest(raw), RefreshToken.digest(raw)
  end
end
