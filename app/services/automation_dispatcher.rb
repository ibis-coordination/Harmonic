# typed: true

class AutomationDispatcher
  extend T::Sig

  # Tenant-level rate limit to prevent system overload
  # Individual rules have their own limits (3/min for agents, 10/min for collective rules)
  # but this ensures no single tenant can overwhelm the system
  TENANT_RUNS_PER_MINUTE = 100

  # For these events, `event.actor` is the recipient (the user being notified)
  # rather than the originator — so the self-trigger guard on agent rules must
  # NOT block them. See `notification_delivery_job.rb` and `reminder_delivery_job.rb`.
  NOTIFICATION_DELIVERED_EVENTS = T.let(["notifications.delivered", "reminders.delivered"].freeze, T::Array[String])

  # Dispatch an event to all matching automation rules
  sig { params(event: Event).void }
  def self.dispatch(event)
    matching_rules = find_matching_rules(event)
    return if matching_rules.empty?

    matching_rules.each do |rule|
      queue_rule_execution(rule, event)
    end
  end

  # Find all enabled automation rules that match this event.
  # Rules are filtered by collective access at the database level:
  # - Collective rules must match the event's collective_id
  # - Agent/user rules require membership in the event's collective
  #
  # Automations are a paid feature, so events on collectives that aren't
  # paid_tier (or main, or on non-billing tenants) match nothing — this
  # pauses automation execution during a `lapsed` state without touching
  # rule config, so a billing restore is instant and zero-loss.
  sig { params(event: Event).returns(T::Array[AutomationRule]) }
  def self.find_matching_rules(event)
    collective_id = event.collective_id
    return [] if collective_id.nil?

    # Fast path: notification-forwarding events fire per-recipient and can be
    # high-volume. Short-circuit when the recipient (event.actor) has no
    # notification-webhook rule. Hits the partial unique index on
    # `(tenant_id, COALESCE(ai_agent_id, user_id))` filtered by webhook_url.
    if NOTIFICATION_DELIVERED_EVENTS.include?(event.event_type)
      recipient_id = event.actor_id
      return [] if recipient_id.nil?
      return [] unless AutomationRule
        .tenant_scoped_only(event.tenant_id)
        .enabled
        .where("(actions->>'webhook_url') IS NOT NULL")
        .where("ai_agent_id = :rid OR user_id = :rid", rid: recipient_id)
        .exists?
    end

    collective = Collective.tenant_scoped_only(event.tenant_id).find_by(id: collective_id)
    return [] if collective.nil?
    # Notification-forwarding events bypass the tier gate — the webhook is a
    # forwarder for the notification system the user already has, not a paid
    # automation. Chat collectives are free-tier; without this bypass, chat
    # message webhooks would never fire on stripe-billing tenants.
    unless NOTIFICATION_DELIVERED_EVENTS.include?(event.event_type)
      return [] unless collective.tier_unlocks_paid_features?
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
    # the query level in find_matching_rules)
    return false unless rule_has_collective_access?(rule, event)

    # Check mention filter for agent rules
    if rule.agent_rule? && rule.mention_filter.present?
      ai_agent = rule.ai_agent
      return false unless ai_agent
      return false unless AutomationMentionFilter.matches?(event, ai_agent, rule.mention_filter)
    end

    # Check conditions
    return false unless AutomationConditionEvaluator.evaluate_all(rule.conditions, event)

    # Don't trigger if the actor is the same agent (prevent self-triggering),
    # except for notification-delivered events where actor==recipient is exactly
    # when the webhook should fire.
    if rule.agent_rule? && event.actor_id == rule.ai_agent_id &&
       !NOTIFICATION_DELIVERED_EVENTS.include?(event.event_type)
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

  # Queue execution of a rule for an event
  sig { params(rule: AutomationRule, event: Event).void }
  def self.queue_rule_execution(rule, event)
    # Chain protection: prevent infinite loops and cascade explosions
    # This applies to ALL rules (agent and collective)
    unless AutomationContext.can_execute_rule?(rule)
      # Logging is handled inside can_execute_rule?
      return
    end

    # Tenant-level rate limit: prevent any single tenant from overwhelming the system
    unless tenant_within_rate_limit?(event.tenant_id)
      Rails.logger.info(
        "[AutomationDispatcher] Tenant rate limit reached for tenant #{event.tenant_id} " \
        "(limit: #{TENANT_RUNS_PER_MINUTE}/min)"
      )
      emit_rate_limit_metric(event.tenant_id, "tenant", rule_type_for_metrics(rule))
      return
    end

    # Record this execution in the chain BEFORE per-rule rate limit check
    # (so even rate-limited rules count toward chain limits)
    AutomationContext.record_rule_execution!(rule, event)

    # Rate limit for all rules to prevent runaway execution
    # Agent rules + notification webhooks: 3/min (conservative — agents can do
    # lots of work; notification webhooks fire per notification and can be
    # high-volume during active periods).
    # Other rules (e.g., collective YAML automations): 10/min.
    max_per_minute = (rule.agent_rule? || rule.notification_webhook_rule?) ? 3 : 10

    recent_runs = AutomationRuleRun
      .where(automation_rule: rule, tenant_id: event.tenant_id)
      .where("created_at > ?", 1.minute.ago)
      .count

    if recent_runs >= max_per_minute
      Rails.logger.info(
        "[AutomationDispatcher] Rate limiting rule #{rule.id} " \
        "(#{recent_runs} runs in last minute, limit: #{max_per_minute})"
      )
      emit_rate_limit_metric(event.tenant_id, "per_rule", rule_type_for_metrics(rule))
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

  # Check if tenant is within the global rate limit
  sig { params(tenant_id: String).returns(T::Boolean) }
  def self.tenant_within_rate_limit?(tenant_id)
    recent_runs = AutomationRuleRun
      .where(tenant_id: tenant_id)
      .where("created_at > ?", 1.minute.ago)
      .count

    recent_runs < TENANT_RUNS_PER_MINUTE
  end
  private_class_method :tenant_within_rate_limit?

  # Emit metrics for rate limiting (skip in test environment)
  sig { params(tenant_id: String, limit_type: String, rule_type: String).void }
  def self.emit_rate_limit_metric(tenant_id, limit_type, rule_type)
    return if Rails.env.test?

    Yabeda.automations.rate_limited_total.increment(
      { tenant_id: tenant_id, limit_type: limit_type, rule_type: rule_type },
      by: 1
    )
  end
  private_class_method :emit_rate_limit_metric

  # Get rule type string for metrics
  sig { params(rule: AutomationRule).returns(String) }
  def self.rule_type_for_metrics(rule)
    rule.agent_rule? ? "agent" : "collective"
  end
  private_class_method :rule_type_for_metrics
end
