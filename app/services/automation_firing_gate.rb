# typed: true

# The one checkpoint that answers "is this rule live and allowed to fire
# right now." All four trigger paths — event, schedule, webhook, manual —
# fire rules through here, so liveness (enabled, not deleted), the tier
# gate, chain protection, and both rate limits have a single home.
#
# Refusals carry a reason so each path can answer in its own medium
# (silent skip, HTTP status, action error). `fire!` is the whole firing
# step: checkpoint, chain recording, run creation, job enqueue.
class AutomationFiringGate
  extend T::Sig

  # Tenant-level rate limit to prevent system overload.
  # Individual rules have their own limits (3/min for agent rules and
  # notification forwarders, 10/min for collective rules), but this
  # ensures no single tenant can overwhelm the system.
  TENANT_RUNS_PER_MINUTE = 100

  class Result < T::Struct
    extend T::Sig

    const :run, T.nilable(AutomationRuleRun)
    const :refusal_reason, T.nilable(Symbol)

    sig { returns(T::Boolean) }
    def allowed?
      refusal_reason.nil?
    end
  end

  sig do
    params(
      rule: AutomationRule,
      source: String,
      trigger_data: T::Hash[T.any(String, Symbol), T.untyped],
      event: T.nilable(Event)
    ).returns(Result)
  end
  def self.fire!(rule, source:, trigger_data:, event: nil)
    # Schedule/webhook/manual firings are chain origins: each starts a
    # fresh chain. Event firings inherit the chain already in progress
    # (restored by the execution job for cascades).
    AutomationContext.clear_chain! unless source == "event"

    reason = refusal_reason_before_recording(rule, event)
    return Result.new(run: nil, refusal_reason: reason) if reason

    # Record this execution in the chain BEFORE the per-rule rate limit
    # check, so even rate-limited rules count toward chain limits.
    AutomationContext.record_rule_execution!(rule, event)

    unless rule_within_rate_limit?(rule)
      emit_rate_limit_metric(rule.tenant_id, "per_rule", rule_scope_for_metrics(rule))
      return Result.new(run: nil, refusal_reason: :rule_rate_limited)
    end

    chain = AutomationContext.chain_to_hash

    run = AutomationRuleRun.create!(
      tenant: rule.tenant,
      collective_id: rule.collective_id,
      automation_rule: rule,
      triggered_by_event: event,
      trigger_source: source,
      trigger_data: trigger_data,
      chain_metadata: chain,
      status: "pending"
    )

    AutomationRuleExecutionJob.perform_later(
      automation_rule_run_id: run.id,
      tenant_id: run.tenant_id,
      chain: chain
    )

    Result.new(run: run, refusal_reason: nil)
  end

  sig { params(rule: AutomationRule, event: T.nilable(Event)).returns(T.nilable(Symbol)) }
  def self.refusal_reason_before_recording(rule, event)
    return :disabled unless rule.enabled? && rule.deleted_at.nil?
    return :tier_locked if tier_locked?(rule, event)
    return :chain_blocked unless AutomationContext.can_execute_rule?(rule)

    unless tenant_within_rate_limit?(rule.tenant_id)
      Rails.logger.info("[AutomationFiringGate] Tenant rate limit reached for tenant " \
                        "#{rule.tenant_id} (limit: #{TENANT_RUNS_PER_MINUTE}/min)")
      emit_rate_limit_metric(rule.tenant_id, "tenant", rule_scope_for_metrics(rule)) # vocab-ok
      return :tenant_rate_limited
    end

    nil
  end
  private_class_method :refusal_reason_before_recording

  # Automations are a paid feature: the collective in whose context the
  # rule fires must unlock paid features. For event firings that is the
  # event's collective; otherwise the rule's own (agent- and user-scoped
  # rules without a collective are gated by per-agent billing instead).
  # Single-recipient events are exempt: the forward is part of the
  # notification system the recipient already has, not a paid automation.
  sig { params(rule: AutomationRule, event: T.nilable(Event)).returns(T::Boolean) }
  def self.tier_locked?(rule, event)
    return false if event && EventTypeRegistry.single_recipient?(event.event_type)

    collective_id = event ? event.collective_id : rule.collective_id
    return false if collective_id.nil?

    collective = event ? event.collective : rule.collective
    return true if collective.nil?

    !collective.tier_unlocks_paid_features?
  end
  private_class_method :tier_locked?

  sig { params(rule: AutomationRule).returns(T::Boolean) }
  def self.rule_within_rate_limit?(rule)
    # Agent rules + notification forwarders: 3/min (conservative — agents
    # can do lots of work; forwarders fire per notification and can be
    # high-volume during active periods). Other rules: 10/min.
    max_per_minute = (rule.agent_rule? || rule.notification_webhook_rule?) ? 3 : 10

    recent_runs = AutomationRuleRun
      .where(automation_rule: rule, tenant_id: rule.tenant_id)
      .where("created_at > ?", 1.minute.ago)
      .count

    if recent_runs >= max_per_minute
      Rails.logger.info(
        "[AutomationFiringGate] Rate limiting rule #{rule.id} " \
        "(#{recent_runs} runs in last minute, limit: #{max_per_minute})"
      )
      return false
    end

    true
  end
  private_class_method :rule_within_rate_limit?

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
  sig { params(tenant_id: String, limit_type: String, rule_scope: String).void }
  def self.emit_rate_limit_metric(tenant_id, limit_type, rule_scope)
    return if Rails.env.test?

    Yabeda.automations.rate_limited_total.increment(
      { tenant_id: tenant_id, limit_type: limit_type, rule_type: rule_scope },
      by: 1
    )
  end
  private_class_method :emit_rate_limit_metric

  sig { params(rule: AutomationRule).returns(String) }
  def self.rule_scope_for_metrics(rule)
    rule.agent_rule? ? "agent" : "collective"
  end
  private_class_method :rule_scope_for_metrics
end
