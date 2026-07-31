# typed: true

class AutomationDispatcher
  extend T::Sig

  # Event audiences are declared in EventTypeRegistry. For single-recipient
  # types, `event.actor` is the recipient (the user being notified) rather
  # than the originator — so the self-trigger guard on agent rules must NOT
  # block them. See `notification_delivery_job.rb` and `reminder_delivery_job.rb`.

  # Dispatch an event to all matching automation rules. Matching decides
  # which rules may react (audience, filters, conditions); the firing gate
  # decides whether each may fire right now (liveness, tier, chain, rates).
  sig { params(event: Event).void }
  def self.dispatch(event)
    find_matching_rules(event).each do |rule|
      AutomationFiringGate.fire!(
        rule,
        source: "event",
        event: event,
        trigger_data: {
          event_type: event.event_type,
          event_id: event.id,
          actor_id: event.actor_id,
          subject_type: event.subject_type,
          subject_id: event.subject_id,
        }
      )
    end
  end

  # Find all enabled automation rules that match this event.
  # Rules are filtered by collective access at the database level:
  # - Collective rules must match the event's collective_id
  # - Agent/user rules require membership in the event's collective
  #
  # The paid-tier gate is NOT here — AutomationFiringGate refuses firings
  # for collectives that don't unlock paid features, which pauses
  # automation execution during a `lapsed` state without touching rule
  # config, so a billing restore is instant and zero-loss.
  sig { params(event: Event).returns(T::Array[AutomationRule]) }
  def self.find_matching_rules(event)
    collective_id = event.collective_id
    return [] if collective_id.nil?

    # Single-recipient events fire per-recipient (event.actor is the
    # recipient) and their content is private to that recipient: ONLY rules
    # owned by the recipient may fire. Matching by collective membership
    # here would deliver one member's notification payloads to every other
    # member's webhook, and collective rules have no owner, so they never
    # match per-recipient events. The event's collective is provenance
    # (every Event row is collective-scoped), not a routing input — no
    # membership check and no tier gate: the webhook forwards the
    # notification system the recipient already has, not a paid automation.
    if EventTypeRegistry.single_recipient?(event.event_type)
      recipient_id = event.actor_id
      return [] if recipient_id.nil?

      return AutomationRule
        .tenant_scoped_only(event.tenant_id)
        .enabled
        .for_event_type(event.event_type)
        .where("ai_agent_id = :rid OR user_id = :rid", rid: recipient_id)
        .select { |rule| matches_rule?(event, rule) }
    end

    # Find rules with collective access in a single query
    rules = AutomationRule
      .tenant_scoped_only(event.tenant_id)
      .enabled
      .for_event_type(event.event_type)
      .where(<<~SQL.squish, collective_id: collective_id)
        (collective_id = :collective_id)
        OR (ai_agent_id IN (SELECT user_id FROM collective_members WHERE collective_id = :collective_id AND archived_at IS NULL))
        OR (user_id IN (SELECT user_id FROM collective_members WHERE collective_id = :collective_id AND archived_at IS NULL))
      SQL

    rules.select do |rule|
      matches_rule?(event, rule)
    end
  end

  # Check if an event matches a specific rule
  sig { params(event: Event, rule: AutomationRule).returns(T::Boolean) }
  def self.matches_rule?(event, rule)
    # Collective access check (redundant safety net — also enforced at
    # the query level in find_matching_rules). Skipped for single-recipient
    # events: those match on rule ownership, and the recipient's own
    # notification forwards regardless of their current membership state
    # in the event's collective.
    unless EventTypeRegistry.single_recipient?(event.event_type)
      return false unless rule_has_collective_access?(rule, event)
    end

    # Check mention filter for agent rules
    if rule.agent_rule? && rule.mention_filter.present?
      ai_agent = rule.ai_agent
      return false unless ai_agent
      return false unless AutomationMentionFilter.matches?(event, ai_agent, rule.mention_filter)
    end

    # Check conditions
    return false unless AutomationConditionEvaluator.evaluate_all(rule.conditions, event)

    # Don't trigger if the actor is the same agent (prevent self-triggering),
    # except for single-recipient events where actor==recipient is exactly
    # when the webhook should fire.
    if rule.agent_rule? && event.actor_id == rule.ai_agent_id &&
       !EventTypeRegistry.single_recipient?(event.event_type)
      return false
    end

    true
  end

  # Verify the rule owner has access to the event's collective.
  # - Collective rules: must match the event's collective_id exactly
  # - Agent rules: the agent must be a member of the event's collective
  # - User rules: the user must be a member of the event's collective
  sig { params(rule: AutomationRule, event: Event).returns(T::Boolean) }
  def self.rule_has_collective_access?(rule, event)
    event_collective_id = event.collective_id
    return false if event_collective_id.nil?

    if rule.collective_rule?
      rule.collective_id == event_collective_id
    elsif rule.agent_rule?
      CollectiveMember
        .where(collective_id: event_collective_id, user_id: rule.ai_agent_id)
        .where(archived_at: nil)
        .exists?
    elsif rule.user_rule?
      CollectiveMember
        .where(collective_id: event_collective_id, user_id: rule.user_id)
        .where(archived_at: nil)
        .exists?
    else
      false
    end
  end
  private_class_method :rule_has_collective_access?
end
