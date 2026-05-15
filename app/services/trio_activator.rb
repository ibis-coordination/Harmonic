# typed: true
# frozen_string_literal: true

# Turns Trio on or off for a single Collective.
#
# Activation either bootstraps fresh state (TrioSeeder creates the user
# and joins it as a CollectiveMember; default automation rules are seeded)
# or restores previously deactivated state (unarchives the CollectiveMember,
# re-enables existing rules, re-links collective.trio_user). The restore
# path preserves any user customizations to the default rules across
# off→on→off→on cycles.
#
# Deactivation archives the trio's CollectiveMember in this collective,
# disables its rules, and nulls out collective.trio_user_id. The trio User
# row and its AutomationRule rows are kept so that a subsequent activation
# can restore them.
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

  sig { params(collective: Collective).void }
  def initialize(collective)
    @collective = collective
  end

  sig { returns(User) }
  def activate!
    ActiveRecord::Base.transaction do
      existing = find_existing_trio
      existing ? restore!(existing) : bootstrap!
    end
  end

  sig { void }
  def deactivate!
    trio = @collective.trio_user
    return unless trio

    ActiveRecord::Base.transaction do
      member = @collective.collective_members.find_by(user_id: trio.id)
      member&.archive!

      AutomationRule.where(ai_agent_id: trio.id).update_all(enabled: false)

      @collective.update!(trio_user_id: nil)
    end
  end

  private

  # Returns the trio User previously linked to this collective, even if its
  # CollectiveMember is currently archived. Returns nil if Trio has never
  # been activated here.
  sig { returns(T.nilable(User)) }
  def find_existing_trio
    return @collective.trio_user if @collective.trio_user

    member = @collective.collective_members
      .joins(:user)
      .where(users: { system_role: "trio" })
      .first
    member&.user
  end

  sig { params(trio: User).returns(User) }
  def restore!(trio)
    member = @collective.collective_members.find_by(user_id: trio.id)
    member.unarchive! if member&.archived?

    AutomationRule.where(ai_agent_id: trio.id).update_all(enabled: true)

    @collective.update!(trio_user: trio)
    trio
  end

  sig { returns(User) }
  def bootstrap!
    trio = TrioSeeder.ensure_for(@collective)
    self.class.seed_default_automations!(trio, T.must(@collective.tenant_id))
    trio
  end

  # Idempotent: skips any default whose (ai_agent_id, event_type) row already
  # exists. Called from `bootstrap!` and from the legacy-trio adoption
  # migration; safe to invoke either way.
  sig { params(trio: User, tenant_id: String).void }
  def self.seed_default_automations!(trio, tenant_id)
    existing_event_types = AutomationRule.where(ai_agent_id: trio.id, trigger_type: "event")
      .map(&:event_type)

    DEFAULT_AUTOMATIONS.each do |attrs|
      event_type = attrs.fetch(:event_type)
      next if existing_event_types.include?(event_type)

      AutomationRule.create!(
        tenant_id: tenant_id,
        ai_agent_id: trio.id,
        created_by_id: trio.id,
        name: attrs.fetch(:name),
        description: attrs.fetch(:description),
        trigger_type: "event",
        trigger_config: {
          "event_type" => event_type,
          "mention_filter" => "self",
          "max_steps" => attrs.fetch(:max_steps, 20),
        },
        conditions: [],
        actions: { "task" => attrs.fetch(:task) },
        enabled: true,
      )
    end
  end

  DEFAULT_AUTOMATIONS = T.let(
    [
      {
        name: "Respond to mentions",
        description: "When @trio is mentioned in a note or comment, navigate and respond.",
        event_type: "note.created",
        max_steps: 20,
        task: <<~TASK,
          You were mentioned by {{event.actor.name}} in {{subject.path}}.
          Navigate there, read the context, and respond appropriately with a comment.
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
    T::Array[T::Hash[Symbol, T.untyped]],
  )
end
