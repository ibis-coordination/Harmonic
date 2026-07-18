# typed: true
# frozen_string_literal: true

# Turns Trio — the built-in persona ensemble (see Personas) — on or off
# for a single Collective (private workspaces included). One feature flag
# ("trio") covers the whole set; there is no per-persona toggle.
#
# Activation either bootstraps fresh state per persona (PersonaSeeder
# creates the user and joins it as a CollectiveMember; the persona's default
# automation rules are seeded) or restores previously deactivated state
# (unarchives the CollectiveMember, re-grants the activation roles,
# re-enables existing rules). The restore path preserves any user
# customizations to the default rules across off→on→off→on cycles.
#
# Every active persona holds three roles on its CollectiveMember row, all
# activator-managed:
#   - its persona role (e.g. "cadence") — identity; @cadence resolves here
#   - the shared ensemble role ("trio") — @trio fans out to all holders
#   - its capability role (e.g. "summarizer") — grantable powers
#
# Deactivation removes all three — the persona role is the activation signal
# that mention resolution, pool funding, and Collective#persona_user key
# off — archives each persona's CollectiveMember, and disables its rules.
# The persona User rows and their AutomationRule rows are kept so that a
# subsequent activation can restore them.
class PersonaActivator
  extend T::Sig

  sig { params(collective: Collective).returns(T::Array[User]) }
  def self.activate!(collective)
    ActiveRecord::Base.transaction do
      ensure_flag!(collective, true)
      Personas.all.map { |persona| new(collective, persona).activate_persona! }
    end
  end

  sig { params(collective: Collective).void }
  def self.deactivate!(collective)
    ActiveRecord::Base.transaction do
      ensure_flag!(collective, false)
      Personas.all.each { |persona| new(collective, persona).deactivate_persona! }
    end
  end

  # Drives the ensemble's state into agreement with the collective's trio
  # feature flag. Idempotent: personas already matching the flag are left
  # alone — which also heals partial states (e.g. a collective enabled
  # before a new persona existed picks it up on the next reconcile). Safe
  # to call after every settings save.
  #
  # Compares desired (`trio_enabled?`) to actual per persona (the persona
  # role being held — `persona_user(...).present?`), not flag-transition
  # deltas — a delta-based check would miss the first activation when the
  # flag was already true via config default.
  sig { params(collective: Collective).void }
  def self.reconcile!(collective)
    desired = collective.trio_enabled?

    Personas.all.each do |persona|
      actual = collective.persona_user(persona.system_role).present?

      if desired && !actual
        new(collective, persona).activate_persona!
      elsif !desired && actual
        new(collective, persona).deactivate_persona!
      end
    end
  end

  # Keep the explicit flag in lockstep with the materialized state. Without
  # this, calling activate!/deactivate! out-of-band (rake task, migration,
  # console) would leave a state where reconcile! reads the flag and undoes
  # the change on the next save.
  sig { params(collective: Collective, value: T::Boolean).void }
  def self.ensure_flag!(collective, value)
    return if collective.feature_flags_hash[Personas::ENSEMBLE_ROLE] == value

    collective.set_feature_flag!(Personas::ENSEMBLE_ROLE, value)
  end
  private_class_method :ensure_flag!

  # Idempotent: skips any default whose (ai_agent_id, event_type) row already
  # exists. Called from `bootstrap!` and from the legacy-trio adoption
  # migration; safe to invoke either way.
  sig { params(agent: User, tenant_id: String).void }
  def self.seed_default_automations!(agent, tenant_id)
    persona = T.must(Personas.fetch(agent.system_role))
    existing_event_types = AutomationRule.where(ai_agent_id: agent.id, trigger_type: "event")
      .flat_map(&:event_types)

    persona.default_automations.each do |attrs|
      event_types = Array(attrs[:event_types] || attrs.fetch(:event_type))
      next if existing_event_types.intersect?(event_types)

      AutomationRule.create!(
        tenant_id: tenant_id,
        ai_agent_id: agent.id,
        created_by_id: agent.id,
        name: attrs.fetch(:name),
        description: attrs.fetch(:description),
        trigger_type: "event",
        trigger_config: {
          "event_types" => event_types,
          "mention_filter" => attrs.fetch(:mention_filter, "self"),
          "max_steps" => attrs.fetch(:max_steps, 20),
        },
        conditions: [],
        actions: { "task" => attrs.fetch(:task) },
        enabled: true
      )
    end
  end

  sig { params(collective: Collective, persona: Personas::Definition).void }
  def initialize(collective, persona)
    @collective = collective
    @persona = persona
  end

  sig { returns(User) }
  def activate_persona!
    ActiveRecord::Base.transaction do
      existing = find_existing_agent
      existing ? restore!(existing) : bootstrap!
    end
  end

  sig { void }
  def deactivate_persona!
    ActiveRecord::Base.transaction do
      agent = @collective.seeded_persona_user(@persona.system_role)
      next unless agent

      member = @collective.collective_members.find_by(user_id: agent.id)
      # Removing the persona role IS deactivation — mention resolution,
      # reconcile!, pool funding, and Collective#persona_user all key off
      # it. The ensemble and capability roles go with it: a deactivated
      # persona is not addressable via @trio and holds no powers.
      member&.remove_roles!(activation_roles)
      member&.archive!
      @collective.clear_persona_user_cache!

      AutomationRule.where(ai_agent_id: agent.id).update_all(enabled: false)
    end
  end

  private

  # Returns the persona User previously seeded for this collective, even if
  # its CollectiveMember is currently archived. Returns nil if the persona
  # has never been activated here.
  sig { returns(T.nilable(User)) }
  def find_existing_agent
    @collective.seeded_persona_user(@persona.system_role)
  end

  sig { params(agent: User).returns(User) }
  def restore!(agent)
    member = @collective.collective_members.find_by(user_id: agent.id)
    member.unarchive! if member&.archived?
    grant_activation_roles!(agent)

    AutomationRule.where(ai_agent_id: agent.id).update_all(enabled: true)

    @collective.ensure_personas_funded!
    agent
  end

  sig { returns(User) }
  def bootstrap!
    agent = PersonaSeeder.ensure_for(@collective, @persona)
    grant_activation_roles!(agent)
    self.class.seed_default_automations!(agent, T.must(@collective.tenant_id))
    @collective.ensure_personas_funded!
    agent
  end

  sig { returns(T::Array[String]) }
  def activation_roles
    [@persona.system_role, Personas::ENSEMBLE_ROLE, @persona.capability_role]
  end

  # The roles are activation state: granted here, removed on deactivate.
  # Mention resolution (@cadence, @trio) keys off them. The memoized persona
  # lookup on this instance is stale the moment the roles change — clear it,
  # or a pre-activation nil read (reconcile!) would pin nil and
  # ensure_personas_funded! would skip funding.
  sig { params(agent: User).void }
  def grant_activation_roles!(agent)
    member = @collective.collective_members.find_by(user_id: agent.id)
    member&.add_roles!(activation_roles)
    @collective.clear_persona_user_cache!
  end
end
