# typed: true
# frozen_string_literal: true

# Creates (or refreshes) the Trio ai_agent User for a single collective.
#
# Trio is a system-seeded AI agent that opted-in collectives use as their
# in-app assistant. It is an ordinary ai_agent User in every respect except:
#   - system_role: "trio"
#   - parent_id: the collective's identity user (the collective itself is the
#     principal — no human owner, no TrusteeGrant)
#   - no StripeCustomer or ApiToken
#
# Trio handles follow `trio-<collective handle>` — unique per tenant
# (collective handles are) and pointing at the trio's own profile. The @trio
# mention tag resolves collective-locally via the trio persona role
# (MentionParser); no user holds the literal handle "trio".
#
# Idempotent. Safe to call multiple times — returns the collective's existing
# trio without modification on the second call (other than clearing any stale
# cached identity_prompt in agent_configuration). Activation state (the trio
# persona role) is TrioActivator's job, not the seeder's.
class TrioSeeder
  extend T::Sig

  HANDLE = "trio"
  NAME = "Trio"

  sig { params(collective: Collective).returns(User) }
  def self.ensure_for(collective)
    new(collective).ensure
  end

  sig { params(collective: Collective).void }
  def initialize(collective)
    @collective = collective
  end

  sig { returns(User) }
  def ensure
    ActiveRecord::Base.transaction do
      existing = @collective.seeded_persona_user("trio")
      existing ? refresh(existing) : create
    end
  end

  private

  sig { params(trio: User).returns(User) }
  def refresh(trio)
    cfg = (trio.agent_configuration || {}).except("identity_prompt")
    trio.update!(agent_configuration: cfg) if cfg != trio.agent_configuration
    trio
  end

  sig { returns(User) }
  def create
    tenant = T.must(@collective.tenant)
    trio = User.create!(
      name: NAME,
      email: "trio-#{tenant.subdomain}-#{SecureRandom.hex(4)}@system.harmonic.local",
      user_type: "ai_agent",
      system_role: "trio",
      # The collective itself is the accountable principal: trio does the
      # collective's work, and pool draws are authorized against this link
      # (see LLMGateway::PayerResolver).
      parent_id: @collective.identity_user_id,
      agent_configuration: build_agent_configuration,
    )
    tenant.add_user!(trio, handle: pick_handle)
    @collective.add_user!(trio)
    trio
  end

  # Default LLM model for new Trio agents. Resolved from the
  # TRIO_DEFAULT_MODEL env var so deployments can switch Trio's model
  # without a code change. The value must match a `model_name` alias in
  # config/litellm_config.yaml. Operators can override per-trio later via
  # the agent settings page — TrioSeeder.refresh does not overwrite
  # existing values.
  sig { returns(T.nilable(String)) }
  def self.default_model
    ENV["TRIO_DEFAULT_MODEL"].presence
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_agent_configuration
    # identity_prompt is intentionally omitted — system agents resolve their
    # prompt dynamically via User#effective_identity_prompt.
    #
    # `capabilities` key is intentionally omitted — absent means "all
    # grantable actions allowed" per CapabilityCheck. An empty array would
    # mean "no actions allowed", which would prevent Trio from posting any
    # comment or other response.
    cfg = { "mode" => "internal" }
    model = self.class.default_model
    cfg["model"] = model if model
    cfg
  end

  sig { returns(String) }
  def pick_handle
    TenantUser.persona_handle_for(
      tenant_id: T.must(@collective.tenant_id),
      tag: HANDLE,
      collective_handle: T.must(@collective.handle),
    )
  end
end
