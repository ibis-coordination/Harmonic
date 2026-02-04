require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  def setup
    @tenant, @superagent, @user = create_tenant_superagent_user
  end

  # === Token Generation Tests ===

  test "token hash is automatically generated on create" do
    token = ApiToken.new(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes
    )

    assert_nil token.token_hash
    token.save!
    assert_not_nil token.token_hash
    assert_equal 64, token.token_hash.length  # SHA256 hex = 64 chars
    assert_equal 40, token.plaintext_token.length  # hex(20) = 40 chars
    assert_equal 4, token.token_prefix.length  # First 4 chars
  end

  test "each token hash is unique" do
    tokens = 5.times.map do
      ApiToken.create!(
        tenant: @tenant,
        user: @user,
        scopes: ApiToken.read_scopes
      )
    end

    token_hashes = tokens.map(&:token_hash)
    assert_equal token_hashes.uniq.length, tokens.length
  end

  # === Scope Validation Tests ===

  test "valid scopes are accepted" do
    token = ApiToken.new(
      tenant: @tenant,
      user: @user,
      scopes: ["read:all", "create:notes"]
    )
    assert token.valid?
  end

  test "empty scopes are rejected" do
    token = ApiToken.new(
      tenant: @tenant,
      user: @user,
      scopes: []
    )
    assert_not token.valid?
    assert_includes token.errors[:scopes], "can't be blank"
  end

  test "read_scopes class method returns read-only scopes" do
    scopes = ApiToken.read_scopes
    assert_includes scopes, "read:all"
    assert_not scopes.any? { |s| s.start_with?("create") }
  end

  test "write_scopes class method returns write scopes" do
    scopes = ApiToken.write_scopes
    assert scopes.any? { |s| s.start_with?("create") }
    assert scopes.any? { |s| s.start_with?("update") }
    assert scopes.any? { |s| s.start_with?("delete") }
  end

  test "valid_scopes includes all action/resource combinations" do
    scopes = ApiToken.valid_scopes
    assert scopes.include?("read:all")
    assert scopes.include?("create:notes")
    assert scopes.include?("update:decisions")
    assert scopes.include?("delete:commitments")
  end

  # === Expiration Tests ===

  test "token without expiration is not expired" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    assert_not token.expired?
    assert token.active?
  end

  test "token past expiration is expired" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.day.ago
    )

    assert token.expired?
    assert_not token.active?
  end

  test "token expiring today is not yet expired" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.hour.from_now
    )

    assert_not token.expired?
  end

  # === Soft Delete Tests ===

  test "delete! sets deleted_at timestamp" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    assert_nil token.deleted_at
    assert_not token.deleted?

    token.delete!

    assert_not_nil token.deleted_at
    assert token.deleted?
    assert_not token.active?
  end

  test "deleted token is not active even if not expired" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    token.delete!

    assert_not token.active?
  end

  # === Token Usage Tracking ===

  test "token_used! updates last_used_at" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    assert_nil token.last_used_at

    token.token_used!

    assert_not_nil token.last_used_at
    assert_in_delta Time.current, token.last_used_at, 1.second
  end

  # === API JSON Tests ===

  test "api_json returns plaintext token immediately after creation" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Test Token",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    json = token.api_json

    assert_equal token.id, json[:id]
    assert_equal "Test Token", json[:name]
    assert_equal @user.id, json[:user_id]
    # On creation, plaintext is available and returned
    assert_not json[:token].include?("*")
    assert_equal token.plaintext_token, json[:token]
    assert_equal token.scopes, json[:scopes]
    assert json[:active]
  end

  test "api_json returns obfuscated token after reload" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    # After reload, plaintext_token is lost
    token.reload
    json = token.api_json

    assert json[:token].include?("*")
    assert_equal token.obfuscated_token, json[:token]
  end

  test "obfuscated_token shows first 4 characters from token_prefix" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    plaintext = token.plaintext_token
    obfuscated = token.obfuscated_token

    assert_equal plaintext[0..3], obfuscated[0..3]
    assert_equal token.token_prefix, obfuscated[0..3]
    assert obfuscated.include?("*")
  end

  # === Association Tests ===

  test "token belongs to tenant" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    assert_equal @tenant, token.tenant
  end

  test "token belongs to user" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    assert_equal @user, token.user
  end

  test "user can have multiple tokens" do
    3.times do
      ApiToken.create!(
        tenant: @tenant,
        user: @user,
        scopes: ApiToken.read_scopes,
        expires_at: 1.year.from_now
      )
    end

    assert_equal 3, @user.api_tokens.count
  end

  # === Admin Flag Tests ===

  test "sys_admin? returns false by default" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    assert_not token.sys_admin?
  end

  test "sys_admin? returns true when sys_admin flag is set" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      sys_admin: true
    )
    assert token.sys_admin?
  end

  test "app_admin? returns false by default" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    assert_not token.app_admin?
  end

  test "app_admin? returns true when app_admin flag is set" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      app_admin: true
    )
    assert token.app_admin?
  end

  test "tenant_admin? returns false by default" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    assert_not token.tenant_admin?
  end

  test "tenant_admin? returns true when tenant_admin flag is set" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      tenant_admin: true
    )
    assert token.tenant_admin?
  end

  test "admin flags can be combined" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      sys_admin: true,
      app_admin: true,
      tenant_admin: true
    )
    assert token.sys_admin?
    assert token.app_admin?
    assert token.tenant_admin?
  end

  # === Token Authentication Tests ===

  test "authenticate finds token by hashed value" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    plaintext = token.plaintext_token

    found = ApiToken.authenticate(plaintext, tenant_id: @tenant.id)

    assert_equal token, found
  end

  test "authenticate returns nil for wrong token" do
    ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    found = ApiToken.authenticate("wrong-token", tenant_id: @tenant.id)

    assert_nil found
  end

  test "authenticate returns nil for deleted token" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    plaintext = token.plaintext_token
    token.delete!

    found = ApiToken.authenticate(plaintext, tenant_id: @tenant.id)

    assert_nil found
  end

  test "authenticate returns nil for wrong tenant" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    plaintext = token.plaintext_token
    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")

    found = ApiToken.authenticate(plaintext, tenant_id: other_tenant.id)

    assert_nil found
  end

  test "hash_token produces consistent SHA256 hash" do
    token_string = "test-token-123"
    expected_hash = Digest::SHA256.hexdigest(token_string)

    assert_equal expected_hash, ApiToken.hash_token(token_string)
    assert_equal expected_hash, ApiToken.hash_token(token_string)  # Consistent
  end

  # === Internal Token Tests ===

  test "internal? returns false by default" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    assert_not token.internal?
  end

  test "internal scope returns only internal tokens" do
    external = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )
    internal = ApiToken.create_internal_token(user: @user, tenant: @tenant)

    internal_tokens = @user.api_tokens.internal
    external_tokens = @user.api_tokens.external

    assert_includes internal_tokens, internal
    assert_not_includes internal_tokens, external
    assert_includes external_tokens, external
    assert_not_includes external_tokens, internal
  end

  # === Ephemeral Internal Token Tests ===

  test "create_internal_token creates valid internal token" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant)

    assert token.internal?
    assert_equal @user, token.user
    assert_equal @tenant, token.tenant
    assert_equal "Internal Agent Token", token.name
    assert token.plaintext_token.present?, "plaintext_token should be available immediately after creation"
  end

  test "create_internal_token plaintext_token is valid for authentication" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant)
    plaintext = token.plaintext_token

    # Verify it matches by checking authentication works
    authenticated = ApiToken.authenticate(plaintext, tenant_id: @tenant.id)
    assert_equal token.id, authenticated.id
  end

  test "create_internal_token sets 1 hour default expiry" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant)

    assert_in_delta 1.hour.from_now, token.expires_at, 5.seconds
  end

  test "create_internal_token accepts custom expiry" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, expires_in: 30.minutes)

    assert_in_delta 30.minutes.from_now, token.expires_at, 5.seconds
  end

  test "create_internal_token always creates new token" do
    token1 = ApiToken.create_internal_token(user: @user, tenant: @tenant)
    token2 = ApiToken.create_internal_token(user: @user, tenant: @tenant)

    # Each call creates a fresh token (ephemeral pattern)
    assert_not_equal token1.id, token2.id
  end

  test "internal token can be destroyed for cleanup" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant)
    token_id = token.id

    token.destroy

    # Token should be fully deleted (not soft-deleted)
    assert_nil ApiToken.unscope(where: :internal).find_by(id: token_id)
  end

  # === Security: Internal Token Protection Tests ===

  test "cannot create internal token via direct create with internal flag" do
    # This simulates an attacker trying to pass internal: true through the API
    assert_raises ActiveRecord::RecordInvalid do
      ApiToken.create!(
        user: @user,
        tenant: @tenant,
        internal: true,
        scopes: ApiToken.read_scopes,
        name: "Malicious Internal Token",
        expires_at: 1.year.from_now
      )
    end
  end

  test "internal token creation via create! fails without allow_internal_token flag" do
    token = ApiToken.new(
      user: @user,
      tenant: @tenant,
      internal: true,
      scopes: ApiToken.read_scopes,
      name: "Malicious Internal Token",
      expires_at: 1.year.from_now
    )

    assert_not token.valid?
    assert_includes token.errors[:internal], "cannot be set to true via external API"
  end

  test "internal token creation via create_internal_token succeeds with allow flag" do
    # This should work because create_internal_token sets allow_internal_token
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant)

    assert token.persisted?
    assert token.internal?
  end

  test "setting internal to false does not require allow flag" do
    # External tokens (internal: false) should be creatable normally
    token = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      internal: false,
      scopes: ApiToken.read_scopes,
      name: "External Token",
      expires_at: 1.year.from_now
    )

    assert token.persisted?
    assert_not token.internal?
  end
end
