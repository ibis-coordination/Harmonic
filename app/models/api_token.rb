# typed: true

class ApiToken < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :user
  belongs_to :context, polymorphic: true, optional: true

  # Default scope to external tokens only (merged with tenant scope from ApplicationRecord)
  # This prevents accidentally exposing internal tokens by forgetting to filter
  default_scope { where(internal: false) }

  # Scope for internal tokens - unscopes the external default but keeps tenant scope
  scope :internal, -> { unscope(where: :internal).where(internal: true) }

  # Explicit external scope (same as default, but useful for clarity)
  scope :external, -> { where(internal: false) }

  # Plaintext token is only available immediately after creation
  attr_accessor :plaintext_token

  # Internal flag for allowing internal token creation - must be set via create_internal_token
  # This prevents external API requests from setting internal: true
  attr_accessor :allow_internal_token

  # Clear plaintext_token on reload since it cannot be recovered from the database
  def reload(*args)
    self.plaintext_token = nil
    super
  end

  # Cap on active external tokens per user — prevents unbounded token creation
  # from a compromised or buggy script. Internal tokens are system-managed and
  # excluded from this count.
  MAX_ACTIVE_TOKENS_PER_USER = 50

  # Every token has exactly one purpose, fixed at creation: rest tokens reach
  # REST/markdown endpoints only, mcp tokens reach /mcp only, llm_gateway
  # tokens reach the LLM gateway only. A leaked token is exactly one kind of
  # incident — data access, audited agent action, or spend with no data access.
  TOKEN_TYPES = ["rest", "mcp", "llm_gateway"].freeze
  AGENT_ONLY_TOKEN_TYPES = ["mcp", "llm_gateway"].freeze

  validates :token_hash, presence: true, uniqueness: true
  validates :scopes, presence: true
  validates :client_name, length: { maximum: 64 }, allow_blank: true
  validates :token_type, inclusion: { in: TOKEN_TYPES }
  validate :validate_scopes
  validate :internal_tokens_require_allow_flag
  validate :context_matches_internal_flag
  validate :token_type_allowed_for_user
  validate :token_type_immutable
  validate :user_must_not_be_internal_agent, on: :create
  validate :active_token_count_within_limit, on: :create

  before_validation :generate_token_hash

  sig { returns(T::Array[String]) }
  def self.valid_actions
    ["create", "read", "update", "delete"]
  end

  sig { returns(T::Array[String]) }
  def valid_actions
    self.class.valid_actions
  end

  sig { returns(T::Array[String]) }
  def self.valid_resources
    ["all", "notes", "confirmations",
     "decisions", "options", "votes", "decision_participants",
     "commitments", "commitment_participants",
     "cycles", "users", "api_tokens",]
  end

  sig { returns(T::Array[String]) }
  def valid_resources
    self.class.valid_resources
  end

  # TODO: - remove the invalid scopes, e.g. 'create:cycles', 'update:results', etc.
  sig { returns(T::Array[String]) }
  def self.valid_scopes
    valid_actions.product(valid_resources).map { |a, r| "#{a}:#{r}" }
  end

  sig { returns(T::Array[String]) }
  def valid_scopes
    self.class.valid_scopes
  end

  sig { returns(T::Array[String]) }
  def self.read_scopes
    # valid_scopes.select { |scope| scope.start_with?('read') }
    ["read:all"]
  end

  sig { returns(T::Array[String]) }
  def self.write_scopes
    # valid_scopes.select { |scope| scope.start_with?('create', 'update', 'delete') }
    ["create:all", "update:all", "delete:all"]
  end

  sig { params(scope: String).returns(T::Boolean) }
  def self.valid_scope?(scope)
    action, resource = scope.split(":")
    valid_actions.include?(action) && valid_resources.include?(resource)
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      id: id,
      name: name,
      user_id: user_id,
      token_prefix: token_prefix,
      scopes: scopes,
      active: active?,
      expires_at: expires_at,
      last_used_at: last_used_at,
      created_at: created_at,
      updated_at: updated_at,
    }
    # Plaintext is only available immediately after creation; include it then
    # so the caller can save it. The full token is never recoverable later.
    response[:token] = plaintext_token if plaintext_token.present?
    response
  end

  sig { returns(String) }
  def obfuscated_token
    (token_prefix || "????") + "*********"
  end

  sig { returns(String) }
  def base_path
    "/u/#{T.must(user).handle}/settings/tokens"
  end

  sig { returns(String) }
  def path
    "#{base_path}/#{id}"
  end

  sig { returns(T::Boolean) }
  def active?
    !deleted? && !expired?
  end

  sig { returns(T::Boolean) }
  def expired?
    T.must(expires_at) < Time.current
  end

  sig { returns(T::Boolean) }
  def deleted?
    !deleted_at.nil?
  end

  sig { returns(T::Boolean) }
  def sys_admin?
    sys_admin == true
  end

  sig { returns(T::Boolean) }
  def app_admin?
    app_admin == true
  end

  sig { returns(T::Boolean) }
  def tenant_admin?
    tenant_admin == true
  end

  sig { returns(T::Boolean) }
  def internal?
    internal == true
  end

  sig { returns(T::Boolean) }
  def rest_type?
    token_type == "rest"
  end

  sig { returns(T::Boolean) }
  def mcp_type?
    token_type == "mcp"
  end

  sig { returns(T::Boolean) }
  def llm_gateway_type?
    token_type == "llm_gateway"
  end

  sig { returns(String) }
  def client_label
    client_name.presence || name.to_s
  end

  # Create a new ephemeral internal token.
  # Token should be deleted when the run completes.
  # The plaintext is available via token.plaintext_token immediately after creation.
  #
  # @param user [User] The user to create the token for
  # @param tenant [Tenant] The tenant context
  # @param context [AiAgentTaskRun, AutomationRuleRun] The run that owns this token
  # @param expires_in [ActiveSupport::Duration] How long until the token expires (default: 1 hour)
  # @return [ApiToken] The created token with plaintext_token available
  sig do
    params(
      user: User,
      tenant: Tenant,
      context: T.any(AiAgentTaskRun, AutomationRuleRun),
      expires_in: ActiveSupport::Duration,
      token_type: String
    ).returns(ApiToken)
  end
  # `token_type:` is chosen by the caller. AgentRunnerDispatchService passes
  # "mcp" because all agent-acting calls go through /mcp via the agent-runner's
  # McpClient (locking the token to /mcp closes the audit-bypass hole where a
  # leaked token could be used directly without producing an McpToolCallLog
  # row). MarkdownUiService's automation path uses the default "rest" because
  # automations dispatch against the direct action endpoints, not /mcp.
  def self.create_internal_token(user:, tenant:, context:, expires_in: 1.hour, token_type: "rest")
    token = new(
      user: user,
      tenant: tenant,
      internal: true,
      scopes: valid_scopes,
      name: "Internal Agent Token",
      expires_at: Time.current + expires_in,
      context: context,
      token_type: token_type
    )
    # Set the allow flag to bypass the validation - only this method can create internal tokens
    token.allow_internal_token = true
    token.save!
    token
  end

  sig { void }
  def delete!
    self.deleted_at ||= T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
  end

  sig { void }
  def token_used!
    update!(last_used_at: Time.current)
  end

  sig { params(action: String, resource_model: T.nilable(T::Class[T.anything])).returns(T::Boolean) }
  def can?(action, resource_model)
    action = {
      "POST" => "create", "GET" => "read", "PUT" => "update", "PATCH" => "update", "DELETE" => "delete",
    }[action] || action
    raise "Invalid action: #{action}" unless valid_actions.include?(action)
    return true if T.must(scopes).include?("all") || T.must(scopes).include?("#{action}:all")
    return false if resource_model.nil?

    resource_name = resource_model.to_s.underscore.pluralize
    raise "Invalid resource: #{resource_name}" unless valid_resources.include?(resource_name)
    raise "Resource model #{resource_model} does not respond to api_json" unless resource_model.method_defined?(:api_json)

    T.must(scopes).include?("#{action}:#{resource_name}")
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_create?(resource_model)
    can?("create", resource_model)
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_read?(resource_model)
    can?("read", resource_model)
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_update?(resource_model)
    can?("update", resource_model)
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_delete?(resource_model)
    can?("delete", resource_model)
  end

  # Authenticate by hashing the provided token and looking up the hash.
  # Note: This unscopes the default external-only filter to allow internal token auth.
  sig { params(token_string: String, tenant_id: T.untyped).returns(T.nilable(ApiToken)) }
  def self.authenticate(token_string, tenant_id:)
    return nil if token_string.blank?

    token_hash = hash_token(token_string)
    unscope(where: :internal).find_by(token_hash: token_hash, deleted_at: nil, tenant_id: tenant_id)
  end

  # Authenticate a Bearer key presented to the LLM gateway. The gateway is a
  # single cross-tenant edge (llm.<hostname>), so unlike `.authenticate` there
  # is no tenant context yet — the token itself identifies the tenant, and the
  # caller re-scopes the thread to it after this lookup. Bypassing the tenant
  # scope is safe here because the unguessable 256-bit hash IS the credential:
  # the lookup is the authentication, the same pre-tenant character as User
  # auth. Only user-issued llm_gateway-type keys match; expiry is a call-site
  # check (same convention as `.authenticate`).
  sig { params(token_string: String).returns(T.nilable(ApiToken)) }
  def self.authenticate_llm_gateway(token_string)
    return nil if token_string.blank?

    unscoped.find_by(token_hash: hash_token(token_string), deleted_at: nil, internal: false, token_type: "llm_gateway") # unscoped-allowed — cross-tenant auth by unguessable hash; tenant is derived FROM the token
  end

  sig { params(token_string: String).returns(String) }
  def self.hash_token(token_string)
    Digest::SHA256.hexdigest(token_string)
  end

  private

  sig { void }
  def generate_token_hash
    return if token_hash.present?

    # Generate a new random token
    new_token = SecureRandom.hex(20)

    # Store plaintext temporarily for returning to user on creation
    self.plaintext_token = new_token

    # Store the hash and prefix
    self.token_hash = self.class.hash_token(new_token)
    self.token_prefix = new_token[0..3]
  end

  sig { void }
  def validate_scopes
    T.must(scopes).each do |scope|
      scope.split(":")
      errors.add(:scopes, "Invalid scope: #{scope}") unless ApiToken.valid_scope?(scope)
    end
  end

  # Prevent external API requests from creating internal tokens by requiring
  # the allow_internal_token flag which can only be set via create_internal_token
  # Only validates on create - existing internal tokens in the DB are allowed to be updated
  sig { void }
  def internal_tokens_require_allow_flag
    return unless new_record? # Only check on create, not update

    return unless internal? && !allow_internal_token

    errors.add(:internal, "cannot be set to true via external API")
  end

  sig { void }
  def token_type_allowed_for_user
    return unless AGENT_ONLY_TOKEN_TYPES.include?(token_type)
    return if user&.ai_agent?

    errors.add(:token_type, "#{token_type} tokens can only belong to AI agents")
  end

  # One purpose per credential, for the credential's whole life. Changing the
  # type would silently re-point what a leaked or long-lived token can reach.
  sig { void }
  def token_type_immutable
    return if new_record?
    return unless token_type_changed?

    errors.add(:token_type, "cannot be changed after creation")
  end

  # Internal agents act only through the agent-runner's ephemeral internal
  # tokens; they cannot hold user-issued API keys. Create-only so legacy rows
  # can still be revoked/updated.
  sig { void }
  def user_must_not_be_internal_agent
    return if internal?
    return unless user&.internal_ai_agent?

    errors.add(:user, "internal agents cannot have API keys")
  end

  # Internal tokens must have a context (AiAgentTaskRun or AutomationRuleRun)
  # and external tokens must not have a context.
  sig { void }
  def context_matches_internal_flag
    return unless new_record?

    if internal? && context.nil?
      errors.add(:context, "is required for internal tokens")
    elsif !internal? && context.present?
      errors.add(:context, "must be blank for external tokens")
    end
  end

  # Cap external tokens per user at MAX_ACTIVE_TOKENS_PER_USER. Counts only
  # tokens that are not deleted and not expired. Internal tokens are excluded.
  sig { void }
  def active_token_count_within_limit
    return if internal?
    return if user_id.nil? || tenant_id.nil?

    active_count = ApiToken
      .where(user_id: user_id, tenant_id: tenant_id, internal: false, deleted_at: nil)
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
      .count

    return unless active_count >= MAX_ACTIVE_TOKENS_PER_USER

    errors.add(:base, "Maximum of #{MAX_ACTIVE_TOKENS_PER_USER} active API tokens reached. Delete an existing token before creating a new one.")
  end
end
