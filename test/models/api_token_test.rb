require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    @context = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: AutomationRule.create!(
        tenant: @tenant,
        collective: @collective,
        name: "Token test rule",
        trigger_type: "manual",
        trigger_config: {},
        actions: [],
        created_by: @user
      ),
      trigger_source: "manual",
      status: "pending"
    )
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
    assert_equal 64, token.token_hash.length # SHA256 hex = 64 chars
    assert_equal 40, token.plaintext_token.length # hex(20) = 40 chars
    assert_equal 4, token.token_prefix.length # First 4 chars
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
    assert_not(scopes.any? { |s| s.start_with?("create") })
  end

  test "write_scopes class method returns write scopes" do
    scopes = ApiToken.write_scopes
    assert(scopes.any? { |s| s.start_with?("create") })
    assert(scopes.any? { |s| s.start_with?("update") })
    assert(scopes.any? { |s| s.start_with?("delete") })
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

  test "api_json omits the plaintext token after reload, but keeps token_prefix" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now
    )

    # After reload, plaintext_token is lost
    token.reload
    json = token.api_json

    assert_not json.key?(:token), "plaintext token should not be returned after reload"
    assert_equal token.token_prefix, json[:token_prefix]
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
    assert_equal expected_hash, ApiToken.hash_token(token_string) # Consistent
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
    internal = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)

    internal_tokens = @user.api_tokens.internal
    external_tokens = @user.api_tokens.external

    assert_includes internal_tokens, internal
    assert_not_includes internal_tokens, external
    assert_includes external_tokens, external
    assert_not_includes external_tokens, internal
  end

  # === Ephemeral Internal Token Tests ===

  test "create_internal_token creates valid internal token" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)

    assert token.internal?
    assert_equal @user, token.user
    assert_equal @tenant, token.tenant
    assert_equal "Internal Agent Token", token.name
    assert token.plaintext_token.present?, "plaintext_token should be available immediately after creation"
  end

  test "create_internal_token plaintext_token is valid for authentication" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)
    plaintext = token.plaintext_token

    # Verify it matches by checking authentication works
    authenticated = ApiToken.authenticate(plaintext, tenant_id: @tenant.id)
    assert_equal token.id, authenticated.id
  end

  test "create_internal_token sets 1 hour default expiry" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)

    assert_in_delta 1.hour.from_now, token.expires_at, 5.seconds
  end

  test "create_internal_token accepts custom expiry" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context, expires_in: 30.minutes)

    assert_in_delta 30.minutes.from_now, token.expires_at, 5.seconds
  end

  test "create_internal_token always creates new token" do
    token1 = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)
    token2 = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)

    # Each call creates a fresh token (ephemeral pattern)
    assert_not_equal token1.id, token2.id
  end

  test "internal token can be destroyed for cleanup" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)
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
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)

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

  # === Context Validation Tests ===

  test "internal token without context is invalid" do
    token = ApiToken.new(
      user: @user,
      tenant: @tenant,
      internal: true,
      scopes: ApiToken.valid_scopes,
      name: "Internal Token",
      expires_at: 1.hour.from_now
    )
    token.allow_internal_token = true

    assert_not token.valid?
    assert_includes token.errors[:context], "is required for internal tokens"
  end

  test "external token with context is invalid" do
    token = ApiToken.new(
      user: @user,
      tenant: @tenant,
      internal: false,
      scopes: ApiToken.read_scopes,
      name: "External Token",
      expires_at: 1.year.from_now,
      context: @context
    )

    assert_not token.valid?
    assert_includes token.errors[:context], "must be blank for external tokens"
  end

  test "internal token with context is valid" do
    token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)

    assert token.persisted?
    assert token.internal?
    assert_equal @context, token.context
  end

  # === Active token cap (MAX_ACTIVE_TOKENS_PER_USER) ===

  test "create raises when user is at the active token cap" do
    ApiToken::MAX_ACTIVE_TOKENS_PER_USER.times do |i|
      ApiToken.create!(tenant: @tenant, user: @user, name: "Filler #{i}", scopes: ["read:all"])
    end
    error = assert_raises(ActiveRecord::RecordInvalid) do
      ApiToken.create!(tenant: @tenant, user: @user, name: "Over cap", scopes: ["read:all"])
    end
    assert_match(/maximum.*active.*token|cap|limit/i, error.message)
  end

  test "cap allows new tokens after a soft delete frees a slot" do
    fillers = ApiToken::MAX_ACTIVE_TOKENS_PER_USER.times.map do |i|
      ApiToken.create!(tenant: @tenant, user: @user, name: "Filler #{i}", scopes: ["read:all"])
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      ApiToken.create!(tenant: @tenant, user: @user, name: "Over", scopes: ["read:all"])
    end
    fillers.first.delete!
    assert ApiToken.create!(tenant: @tenant, user: @user, name: "Below cap", scopes: ["read:all"]).persisted?
  end

  test "cap does not count expired tokens" do
    ApiToken::MAX_ACTIVE_TOKENS_PER_USER.times do |i|
      ApiToken.create!(
        tenant: @tenant,
        user: @user,
        name: "Filler #{i}",
        scopes: ["read:all"],
        expires_at: 1.day.ago
      )
    end
    assert ApiToken.create!(tenant: @tenant, user: @user, name: "Fresh", scopes: ["read:all"]).persisted?
  end

  test "cap does not count internal tokens" do
    ApiToken::MAX_ACTIVE_TOKENS_PER_USER.times do |i|
      ApiToken.create!(tenant: @tenant, user: @user, name: "External #{i}", scopes: ["read:all"])
    end
    # An internal token can still be created even though the external cap is full
    internal = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)
    assert internal.persisted?
    assert internal.internal?
  end

  # === client_name + client_label ===

  test "client_name defaults to nil" do
    token = ApiToken.create!(tenant: @tenant, user: @user, name: "My token", scopes: ["read:all"])
    assert_nil token.client_name
  end

  test "client_name can be set on creation" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "My token",
      scopes: ["read:all"],
      client_name: "Cursor"
    )
    assert_equal "Cursor", token.client_name
  end

  test "client_label returns client_name when present" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Backing name",
      scopes: ["read:all"],
      client_name: "Claude Code"
    )
    assert_equal "Claude Code", token.client_label
  end

  test "client_label falls back to name when client_name is nil" do
    token = ApiToken.create!(tenant: @tenant, user: @user, name: "Legacy token", scopes: ["read:all"])
    assert_equal "Legacy token", token.client_label
  end

  test "client_label falls back to name when client_name is blank" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Legacy token",
      scopes: ["read:all"],
      client_name: ""
    )
    assert_equal "Legacy token", token.client_label
  end

  test "client_name longer than 64 chars is rejected with a friendly validation error" do
    token = ApiToken.new(
      tenant: @tenant,
      user: @user,
      name: "My token",
      scopes: ["read:all"],
      client_name: "x" * 65
    )
    assert_not token.valid?
    assert token.errors[:client_name].any? { |m| m.match?(/too long|maximum/i) }, "expected a length error, got #{token.errors[:client_name].inspect}"
  end

  test "client_name at the 64-char limit is accepted" do
    token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "My token",
      scopes: ["read:all"],
      client_name: "x" * 64
    )
    assert token.persisted?
    assert_equal 64, token.client_name.length
  end

  # === Token type tests ===

  def create_external_agent
    agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "external" })
    assert agent.external_ai_agent?
    agent
  end

  def create_internal_agent
    agent = create_ai_agent(parent: @user)
    assert agent.internal_ai_agent?
    agent
  end

  def build_token(user:, token_type: nil, **overrides)
    attrs = { tenant: @tenant, user: user, name: "Typed token", scopes: ["read:all"] }.merge(overrides)
    attrs[:token_type] = token_type if token_type
    ApiToken.new(attrs)
  end

  test "token_type defaults to rest" do
    token = build_token(user: @user)
    token.save!
    assert_equal "rest", token.token_type
    assert token.rest_type?
    assert_not token.mcp_type?
    assert_not token.llm_gateway_type?
  end

  test "invalid token_type is rejected" do
    token = build_token(user: @user, token_type: "banana")
    assert_not token.valid?
    assert token.errors[:token_type].any?
  end

  test "mcp type requires an AI agent user" do
    token = build_token(user: @user, token_type: "mcp")
    assert_not token.valid?
    assert token.errors[:token_type].any?, "expected a token_type error for a human mcp token"
  end

  test "llm_gateway type requires an AI agent user" do
    token = build_token(user: @user, token_type: "llm_gateway")
    assert_not token.valid?
    assert token.errors[:token_type].any?, "expected a token_type error for a human llm_gateway token"
  end

  test "an external agent can hold all three token types" do
    agent = create_external_agent
    ["rest", "mcp", "llm_gateway"].each do |type|
      token = build_token(user: agent, token_type: type, name: "#{type} token")
      assert token.valid?, "#{type}: #{token.errors.full_messages.join(", ")}"
      token.save!
    end
  end

  test "internal agents cannot have user-issued tokens of any type" do
    agent = create_internal_agent
    ["rest", "mcp", "llm_gateway"].each do |type|
      token = build_token(user: agent, token_type: type, name: "#{type} token")
      assert_not token.valid?, "#{type} token on an internal agent must be invalid"
      assert token.errors[:user].any?, "expected a user error for #{type}"
    end
  end

  test "system-minted internal tokens for internal agents are exempt" do
    agent = create_internal_agent
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: agent, initiated_by: @user,
      task: "Test", max_steps: 5, status: "queued"
    )
    token = ApiToken.create_internal_token(
      user: agent, tenant: @tenant, context: task_run, token_type: "mcp"
    )
    assert token.persisted?
    assert token.internal?
    assert token.mcp_type?
  end

  test "token_type is immutable after creation" do
    agent = create_external_agent
    token = build_token(user: agent, token_type: "mcp")
    token.save!

    token.token_type = "rest"
    assert_not token.valid?
    assert token.errors[:token_type].any?, "expected an immutability error"
  end
end
