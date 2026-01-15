require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  def setup
    @tenant, @superagent, @user = create_tenant_superagent_user
  end

  # === Token Generation Tests ===

  test "token is automatically generated on create" do
    token = ApiToken.new(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes
    )

    assert_nil token.token
    token.save!
    assert_not_nil token.token
    assert token.token.length > 20  # Should be a substantial token
  end

  test "each token is unique" do
    tokens = 5.times.map do
      ApiToken.create!(
        tenant: @tenant,
        user: @user,
        scopes: ApiToken.read_scopes
      )
    end

    token_values = tokens.map(&:token)
    assert_equal token_values.uniq.length, tokens.length
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

  test "api_json returns expected fields" do
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
    assert json[:token].include?("*")  # Should be obfuscated
    assert_equal token.scopes, json[:scopes]
    assert json[:active]
  end

  test "api_json with full_token includes unobfuscated token" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    json = token.api_json(include: ['full_token'])

    assert_equal token.token, json[:token]
    assert_not json[:token].include?("*")
  end

  test "obfuscated_token shows first 4 characters" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    obfuscated = token.obfuscated_token

    assert_equal token.token[0..3], obfuscated[0..3]
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
end
