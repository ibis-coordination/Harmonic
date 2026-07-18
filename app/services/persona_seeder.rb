# typed: true
# frozen_string_literal: true

# Creates (or refreshes) a built-in persona's ai_agent User for a single
# collective.
#
# Personas (see Personas) are system-seeded AI agents that opted-in
# collectives use as built-in members. Each is an ordinary ai_agent User in
# every respect except:
#   - system_role: the persona's (e.g. "cadence")
#   - parent_id: the collective's identity user (the collective itself is the
#     principal — no human owner, no TrusteeGrant)
#   - no StripeCustomer or ApiToken
#
# Persona handles follow `<tag>-<collective handle>` — unique per tenant
# (collective handles are) and pointing at the persona's own profile. The
# persona mention tags (@cadence, @melody, @counterpoint) and the @trio
# ensemble tag resolve collective-locally via roles (MentionParser); no user
# holds the literal tags.
#
# Idempotent. Safe to call multiple times — returns the collective's existing
# persona agent without modification on the second call (other than clearing
# any stale cached identity_prompt in agent_configuration). Activation state
# (the persona, ensemble, and capability roles) is PersonaActivator's job,
# not the seeder's.
class PersonaSeeder
  extend T::Sig

  sig { params(collective: Collective, persona: Personas::Definition).returns(User) }
  def self.ensure_for(collective, persona)
    new(collective, persona).ensure
  end

  sig { params(collective: Collective, persona: Personas::Definition).void }
  def initialize(collective, persona)
    @collective = collective
    @persona = persona
  end

  sig { returns(User) }
  def ensure
    ActiveRecord::Base.transaction do
      existing = @collective.seeded_persona_user(@persona.system_role)
      existing ? refresh(existing) : create
    end
  end

  private

  sig { params(agent: User).returns(User) }
  def refresh(agent)
    cfg = (agent.agent_configuration || {}).except("identity_prompt")
    agent.update!(agent_configuration: cfg) if cfg != agent.agent_configuration
    agent
  end

  sig { returns(User) }
  def create
    tenant = T.must(@collective.tenant)
    agent = User.create!(
      name: @persona.name,
      email: "#{@persona.system_role}-#{tenant.subdomain}-#{SecureRandom.hex(4)}@system.harmonic.local",
      user_type: "ai_agent",
      system_role: @persona.system_role,
      # The collective itself is the accountable principal: the persona does
      # the collective's work, and pool draws are authorized against this
      # link (see LLMGateway::PayerResolver).
      parent_id: @collective.identity_user_id,
      agent_configuration: build_agent_configuration,
    )
    tenant.add_user!(agent, handle: pick_handle)
    @collective.add_user!(agent)
    agent
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_agent_configuration
    # identity_prompt is intentionally omitted — system agents resolve their
    # prompt dynamically via User#effective_identity_prompt.
    #
    # `capabilities` key is intentionally omitted — absent means "all
    # grantable actions allowed" per CapabilityCheck. An empty array would
    # mean "no actions allowed", which would prevent the persona from
    # posting any comment or other response.
    cfg = { "mode" => "internal" }
    model = @persona.default_model
    cfg["model"] = model if model
    cfg
  end

  sig { returns(String) }
  def pick_handle
    TenantUser.persona_handle_for(
      tenant_id: T.must(@collective.tenant_id),
      tag: @persona.system_role,
      collective_handle: T.must(@collective.handle),
    )
  end
end
