# typed: true

class AutomationDispatcher
  extend T::Sig

  # Dispatch an event to all matching automation rules
  sig { params(event: Event).void }
  def self.dispatch(event)
    return unless event.tenant&.ai_agents_enabled?

    matching_rules = find_matching_rules(event)
    return if matching_rules.empty?

    matching_rules.each do |rule|
      queue_rule_execution(rule, event)
    end
  end

  # Find all enabled automation rules that match this event
  sig { params(event: Event).returns(T::Array[AutomationRule]) }
  def self.find_matching_rules(event)
    # Find all event-triggered rules for this event type
    rules = AutomationRule
      .tenant_scoped_only(event.tenant_id)
      .enabled
      .for_event_type(event.event_type)

    # Filter by mention filter for agent rules
    rules.select do |rule|
      matches_rule?(event, rule)
    end
  end

  # Check if an event matches a specific rule
  sig { params(event: Event, rule: AutomationRule).returns(T::Boolean) }
  def self.matches_rule?(event, rule)
    # Check mention filter for agent rules
    if rule.agent_rule? && rule.mention_filter.present?
      ai_agent = rule.ai_agent
      return false unless ai_agent
      return false unless AutomationMentionFilter.matches?(event, ai_agent, rule.mention_filter)
    end

    # Check conditions
    return false unless AutomationConditionEvaluator.evaluate_all(rule.conditions, event)

    # Don't trigger if the actor is the same agent (prevent self-triggering)
    return false if rule.agent_rule? && event.actor_id == rule.ai_agent_id

    true
  end

  # Queue execution of a rule for an event
  sig { params(rule: AutomationRule, event: Event).void }
  def self.queue_rule_execution(rule, event)
    # Rate limit for agent rules: max 3 task triggers per minute per agent
    if rule.agent_rule?
      recent_runs = AutomationRuleRun
        .where(automation_rule: rule, tenant_id: event.tenant_id)
        .where("created_at > ?", 1.minute.ago)
        .count

      if recent_runs >= 3
        Rails.logger.info("Rate limiting automation rule #{rule.id} for agent #{rule.ai_agent_id}")
        return
      end
    end

    # Create a pending run record
    run = AutomationRuleRun.create!(
      tenant: event.tenant,
      automation_rule: rule,
      triggered_by_event: event,
      trigger_source: "event",
      trigger_data: {
        event_type: event.event_type,
        event_id: event.id,
        actor_id: event.actor_id,
        subject_type: event.subject_type,
        subject_id: event.subject_id,
      },
      status: "pending"
    )

    # Queue the execution job
    AutomationRuleExecutionJob.perform_later(
      automation_rule_run_id: run.id,
      tenant_id: run.tenant_id
    )
  end
end
