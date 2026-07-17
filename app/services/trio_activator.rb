# typed: true
# frozen_string_literal: true

# Turns Trio on or off for a single Collective.
#
# Activation either bootstraps fresh state (TrioSeeder creates the user
# and joins it as a CollectiveMember; default automation rules are seeded)
# or restores previously deactivated state (unarchives the CollectiveMember,
# re-grants the trio persona role, re-enables existing rules). The restore
# path preserves any user customizations to the default rules across
# off→on→off→on cycles.
#
# Deactivation removes the trio persona role — the activation signal that
# mention resolution, pool funding, and Collective#trio_user key off —
# archives the trio's CollectiveMember, and disables its rules. The trio
# User row and its AutomationRule rows are kept so that a subsequent
# activation can restore them.
class TrioActivator
  extend T::Sig

  sig { params(collective: Collective).returns(User) }
  def self.activate!(collective)
    new(collective).activate!
  end

  sig { params(collective: Collective).void }
  def self.deactivate!(collective)
    new(collective).deactivate!
  end

  # Drives Trio state into agreement with the collective's `trio` feature
  # flag. Idempotent: if the flag is on and trio is already active, no-op;
  # likewise for the off case. Safe to call after every settings save.
  #
  # Compares desired (`trio_enabled?`) to actual (the persona role being
  # held — `trio_user.present?`), not flag-transition deltas — a delta-based
  # check would miss the first activation when the flag was already true via
  # config default.
  sig { params(collective: Collective).void }
  def self.reconcile!(collective)
    desired = collective.trio_enabled?
    actual = collective.trio_user.present?

    if desired && !actual
      activate!(collective)
    elsif !desired && actual
      deactivate!(collective)
    end
  end

  # Idempotent: skips any default whose (ai_agent_id, event_type) row already
  # exists. Called from `bootstrap!` and from the legacy-trio adoption
  # migration; safe to invoke either way.
  sig { params(trio: User, tenant_id: String).void }
  def self.seed_default_automations!(trio, tenant_id)
    existing_event_types = AutomationRule.where(ai_agent_id: trio.id, trigger_type: "event")
      .flat_map(&:event_types)

    DEFAULT_AUTOMATIONS.each do |attrs|
      event_types = Array(attrs[:event_types] || attrs.fetch(:event_type))
      next if existing_event_types.intersect?(event_types)

      AutomationRule.create!(
        tenant_id: tenant_id,
        ai_agent_id: trio.id,
        created_by_id: trio.id,
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

  sig { params(collective: Collective).void }
  def initialize(collective)
    @collective = collective
  end

  sig { returns(User) }
  def activate!
    ActiveRecord::Base.transaction do
      ensure_flag!(true)
      existing = find_existing_trio
      existing ? restore!(existing) : bootstrap!
    end
  end

  sig { void }
  def deactivate!
    ActiveRecord::Base.transaction do
      ensure_flag!(false)

      trio = @collective.seeded_persona_user(ReservedHandles::TRIO)
      next unless trio

      member = @collective.collective_members.find_by(user_id: trio.id)
      # Removing the persona role IS deactivation — mention resolution,
      # reconcile!, pool funding, and Collective#trio_user all key off it.
      member&.remove_role!(ReservedHandles::TRIO)
      member&.archive!
      @collective.clear_persona_user_cache!

      AutomationRule.where(ai_agent_id: trio.id).update_all(enabled: false)
    end
  end

  private

  # Keep the explicit flag in lockstep with the materialized state. Without
  # this, calling activate!/deactivate! out-of-band (rake task, migration,
  # console) would leave a state where reconcile! reads the flag and undoes
  # the change on the next save.
  sig { params(value: T::Boolean).void }
  def ensure_flag!(value)
    return if @collective.feature_flags_hash["trio"] == value

    @collective.set_feature_flag!("trio", value)
  end

  # Returns the trio User previously seeded for this collective, even if its
  # CollectiveMember is currently archived. Returns nil if Trio has never
  # been activated here.
  sig { returns(T.nilable(User)) }
  def find_existing_trio
    @collective.seeded_persona_user(ReservedHandles::TRIO)
  end

  sig { params(trio: User).returns(User) }
  def restore!(trio)
    member = @collective.collective_members.find_by(user_id: trio.id)
    member.unarchive! if member&.archived?
    grant_persona_role!(trio)

    AutomationRule.where(ai_agent_id: trio.id).update_all(enabled: true)

    @collective.ensure_trio_funded!
    trio
  end

  sig { returns(User) }
  def bootstrap!
    trio = TrioSeeder.ensure_for(@collective)
    grant_persona_role!(trio)
    self.class.seed_default_automations!(trio, T.must(@collective.tenant_id))
    @collective.ensure_trio_funded!
    trio
  end

  # The persona role is activation state: granted here, removed on
  # deactivate. Mention resolution (@trio) keys off it. The memoized
  # persona lookup on this instance is stale the moment the role changes —
  # clear it, or a pre-activation nil read (reconcile!) would pin nil and
  # ensure_trio_funded! would skip funding.
  sig { params(trio: User).void }
  def grant_persona_role!(trio)
    member = @collective.collective_members.find_by(user_id: trio.id)
    member&.add_role!(ReservedHandles::TRIO)
    @collective.clear_persona_user_cache!
  end

  DEFAULT_AUTOMATIONS = T.let(
    [
      {
        name: "Respond to mentions and replies",
        description: "When @trio is mentioned, or when someone replies to a comment Trio wrote, navigate and respond.",
        event_types: ["note.created", "comment.created"],
        mention_filter: "self_or_reply",
        max_steps: 20,
        task: <<~TASK,
          You were mentioned (or replied to) by {{event.actor.name}} in {{subject.path}}.
          Navigate there, read the context — including the parent thread if this
          is a reply — and respond appropriately with a comment.
        TASK
      },
      {
        name: "Help with new decisions",
        description: "When @trio is mentioned on a new decision, offer analysis.",
        event_type: "decision.created",
        max_steps: 20,
        task: <<~TASK,
          A new decision was created by {{event.actor.name}}: "{{subject.title}}"
          Navigate to {{subject.path}} and review the decision. If you can offer
          helpful analysis or perspective, add a comment with your thoughts on
          the options or considerations.
        TASK
      },
      {
        name: "Acknowledge new commitments",
        description: "When @trio is mentioned on a new commitment, acknowledge it.",
        event_type: "commitment.created",
        max_steps: 15,
        task: <<~TASK,
          A new commitment was created by {{event.actor.name}}: "{{subject.title}}"
          Navigate to {{subject.path}}, read the commitment, and post a brief
          comment acknowledging it and inviting others to participate.
        TASK
      },
    ].freeze,
    T::Array[T::Hash[Symbol, T.untyped]]
  )
end
