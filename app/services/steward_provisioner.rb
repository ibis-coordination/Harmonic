# typed: true
# frozen_string_literal: true

# Provisions steward agents: dedicated AI-agent identities whose only job is
# holding read access to system-admin pages. A steward is a pattern, not a
# user type — a minimal external agent carrying the sys_admin role and one
# read-scope rest token minted with the token-level sys_admin flag. See
# docs/STEWARD_AGENTS.md for the identity model and rationale.
#
# Invoked by the steward:* rake tasks. Callers must already hold a thread
# scope for the target tenant (the rake tasks set one up).
class StewardProvisioner
  extend T::Sig

  class PreconditionFailed < StandardError; end

  TOKEN_NAME = "harmonic-admin steward read"
  REPORT_TOKEN_NAME = "harmonic-admin steward report"
  REPORT_TOKEN_SCOPES = T.let(["read:all", "create:all"].freeze, T::Array[String])
  TOKEN_LIFETIME = 1.year

  class ProvisionResult < T::Struct
    const :steward, User
    const :token, ApiToken
  end

  sig { params(tenant: Tenant, principal_handle: String, handle: String).returns(ProvisionResult) }
  def self.provision!(tenant:, principal_handle:, handle:)
    raise PreconditionFailed, "tenant #{tenant.subdomain} does not have the API enabled (run tenant.enable_api!)" unless tenant.api_enabled?

    principal = find_by_handle(tenant, principal_handle)
    raise PreconditionFailed, "no user with handle #{principal_handle.inspect} on tenant #{tenant.subdomain}" if principal.nil?
    raise PreconditionFailed, "principal #{principal_handle.inspect} must hold the sys_admin role" unless principal.sys_admin?
    raise PreconditionFailed, "handle #{handle.inspect} is already taken on tenant #{tenant.subdomain}" if find_by_handle(tenant, handle)

    steward = T.let(nil, T.nilable(User))
    ActiveRecord::Base.transaction do
      steward = User.create!(
        name: handle.titleize,
        email: "#{SecureRandom.uuid}@not-a-real-email.com",
        user_type: "ai_agent",
        parent_id: principal.id,
        agent_configuration: { "mode" => "external" },
      )
      steward.tenant_user = tenant.add_user!(steward, handle: handle)
      steward.update!(sys_admin: true)
    end

    ProvisionResult.new(steward: T.must(steward), token: mint_token!(T.must(steward), tenant))
  end

  sig { params(tenant: Tenant, handle: String).returns(ApiToken) }
  def self.rotate!(tenant:, handle:)
    steward = find_steward!(tenant, handle)
    new_token = mint_token!(steward, tenant)
    active_rest_tokens(steward).where.not(id: new_token.id).find_each(&:delete!)
    new_token
  end

  # Reporting: the steward joins one designated collective (where its status
  # reports land as notes) and holds a second token that can post content but
  # — carrying no sys_admin flag — cannot read admin pages. The mirror image
  # of the read token's capabilities.
  sig { params(tenant: Tenant, handle: String, collective_handle: String).returns(ApiToken) }
  def self.enable_reporting!(tenant:, handle:, collective_handle:)
    steward = find_steward!(tenant, handle)
    collective = tenant.collectives.find_by(handle: collective_handle)
    raise PreconditionFailed, "no collective with handle #{collective_handle.inspect} on tenant #{tenant.subdomain}" if collective.nil?

    collective.add_user!(steward) unless collective.users.exists?(id: steward.id)
    steward.api_tokens.create!(
      tenant: tenant,
      name: REPORT_TOKEN_NAME,
      token_type: "rest",
      scopes: REPORT_TOKEN_SCOPES,
      expires_at: TOKEN_LIFETIME.from_now,
    )
  end

  sig { params(tenant: Tenant, handle: String).void }
  def self.revoke!(tenant:, handle:)
    steward = find_steward!(tenant, handle)
    active_rest_tokens(steward).find_each(&:delete!)
    steward.update!(sys_admin: false)
  end

  sig { params(steward: User, tenant: Tenant).returns(ApiToken) }
  private_class_method def self.mint_token!(steward, tenant)
    steward.api_tokens.create!(
      tenant: tenant,
      name: TOKEN_NAME,
      token_type: "rest",
      scopes: ApiToken.read_scopes,
      sys_admin: true,
      expires_at: TOKEN_LIFETIME.from_now,
    )
  end

  sig { params(tenant: Tenant, handle: String).returns(User) }
  private_class_method def self.find_steward!(tenant, handle)
    steward = find_by_handle(tenant, handle)
    raise PreconditionFailed, "no steward with handle #{handle.inspect} on tenant #{tenant.subdomain}" if steward.nil? || !steward.ai_agent?

    steward
  end

  sig { params(tenant: Tenant, handle: String).returns(T.nilable(User)) }
  private_class_method def self.find_by_handle(tenant, handle)
    tenant.users.joins(:tenant_users).find_by(tenant_users: { handle: handle, tenant_id: tenant.id })
  end

  sig { params(steward: User).returns(ActiveRecord::Relation) }
  private_class_method def self.active_rest_tokens(steward)
    steward.api_tokens.where(token_type: "rest", deleted_at: nil)
  end
end
