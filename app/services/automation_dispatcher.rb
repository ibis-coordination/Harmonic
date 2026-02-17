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
    # Chain protection: prevent infinite loops and cascade explosions
    # This applies to ALL rules (agent and studio)
    unless AutomationContext.can_execute_rule?(rule)
      # Logging is handled inside can_execute_rule?
      return
    end

    # Record this execution in the chain BEFORE rate limit check
    # (so even rate-limited rules count toward chain limits)
    AutomationContext.record_rule_execution!(rule, event)

    # Rate limit for all rules to prevent runaway execution
    # Agent rules: 3/min (conservative, agents can do lots of work)
    # Studio rules: 10/min (more lenient, typically just webhook/internal actions)
    max_per_minute = rule.agent_rule? ? 3 : 10

    recent_runs = AutomationRuleRun
      .where(automation_rule: rule, tenant_id: event.tenant_id)
      .where("created_at > ?", 1.minute.ago)
      .count

    if recent_runs >= max_per_minute
      Rails.logger.info(
        "[AutomationDispatcher] Rate limiting rule #{rule.id} " \
        "(#{recent_runs} runs in last minute, limit: #{max_per_minute})"
      )
      return
    end

    # Capture current chain state for storage and job args
    chain_metadata = AutomationContext.chain_to_hash

    # Create a pending run record with chain metadata for debugging/tracing
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
      chain_metadata: chain_metadata,
      status: "pending"
    )

    # Queue the execution job with chain context
    AutomationRuleExecutionJob.perform_later(
      automation_rule_run_id: run.id,
      tenant_id: run.tenant_id,
      chain: chain_metadata
    )
  end
end
