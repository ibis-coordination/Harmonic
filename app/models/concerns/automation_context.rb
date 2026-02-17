# typed: true

# Thread-local storage for automation context.
# Used to pass the current automation run ID through to models being created,
# and to track automation chains for cascade/loop prevention.
#
# Example usage:
#   AutomationContext.with_run(run) do
#     Note.create!(text: "Hello")  # Will automatically set automation_rule_run_id
#   end
#
# Chain tracking:
#   AutomationContext.can_execute_rule?(rule)  # Check before executing
#   AutomationContext.record_rule_execution!(rule, event)  # Track execution
#   AutomationContext.chain_to_hash  # Serialize for background jobs
#   AutomationContext.restore_chain!(hash)  # Restore in background jobs
module AutomationContext
  extend T::Sig

  # Chain limits to prevent infinite loops and cascade explosions
  MAX_CHAIN_DEPTH = 3
  MAX_RULES_PER_CHAIN = 10

  # ============================================================================
  # Run Context (existing functionality for resource tracking)
  # ============================================================================

  sig { returns(T.nilable(String)) }
  def self.current_run_id
    Thread.current[:automation_rule_run_id]
  end

  sig { params(id: T.nilable(String)).void }
  def self.current_run_id=(id)
    Thread.current[:automation_rule_run_id] = id
  end

  sig { returns(T.nilable(AutomationRuleRun)) }
  def self.current_run
    return nil unless current_run_id

    AutomationRuleRun.find_by(id: current_run_id)
  end

  # Execute a block with the given automation run as context.
  # Resources created within the block will have automation_rule_run_id set.
  sig do
    type_parameters(:T)
      .params(run: AutomationRuleRun, blk: T.proc.returns(T.type_parameter(:T)))
      .returns(T.type_parameter(:T))
  end
  def self.with_run(run, &blk)
    old_id = current_run_id
    self.current_run_id = run.id
    yield
  ensure
    self.current_run_id = old_id
  end

  sig { void }
  def self.clear!
    self.current_run_id = nil
  end

  # ============================================================================
  # Chain Tracking (for cascade/loop prevention)
  # ============================================================================

  # Get the current chain context, initializing if needed
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def self.current_chain
    Thread.current[:automation_chain] ||= new_chain
  end

  # Create a fresh chain context
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def self.new_chain
    {
      depth: 0,
      executed_rule_ids: Set.new,
      origin_event_id: nil,
    }
  end

  # Check if a rule can execute within the current chain.
  # Returns false if:
  # - Chain depth exceeds MAX_CHAIN_DEPTH
  # - This rule has already executed in this chain (loop detection)
  # - Too many rules have executed in this chain (fan-out protection)
  sig { params(rule: AutomationRule).returns(T::Boolean) }
  def self.can_execute_rule?(rule)
    chain = current_chain

    # Check depth limit
    if chain[:depth] >= MAX_CHAIN_DEPTH
      Rails.logger.info(
        "[AutomationContext] Chain depth limit reached (#{chain[:depth]} >= #{MAX_CHAIN_DEPTH}) " \
        "for rule #{rule.id}"
      )
      emit_chain_blocked_metric(rule.tenant_id, "depth_limit")
      return false
    end

    # Check for loop (same rule executing twice in one chain)
    if chain[:executed_rule_ids].include?(rule.id)
      Rails.logger.info(
        "[AutomationContext] Loop detected: rule #{rule.id} already executed in this chain"
      )
      emit_chain_blocked_metric(rule.tenant_id, "loop_detected")
      return false
    end

    # Check total rules in chain
    if chain[:executed_rule_ids].size >= MAX_RULES_PER_CHAIN
      Rails.logger.info(
        "[AutomationContext] Max rules per chain limit reached " \
        "(#{chain[:executed_rule_ids].size} >= #{MAX_RULES_PER_CHAIN}) for rule #{rule.id}"
      )
      emit_chain_blocked_metric(rule.tenant_id, "max_rules_per_chain")
      return false
    end

    true
  end

  # Record that a rule is being executed in the current chain.
  # Call this BEFORE queueing the rule for execution.
  sig { params(rule: AutomationRule, event: T.nilable(Event)).void }
  def self.record_rule_execution!(rule, event)
    chain = current_chain
    chain[:depth] += 1
    chain[:executed_rule_ids] << rule.id
    chain[:origin_event_id] ||= event&.id
  end

  # Serialize chain context for passing through background jobs
  sig { returns(T::Hash[String, T.untyped]) }
  def self.chain_to_hash
    chain = current_chain
    {
      "depth" => chain[:depth],
      "executed_rule_ids" => chain[:executed_rule_ids].to_a,
      "origin_event_id" => chain[:origin_event_id],
    }
  end

  # Restore chain context from a hash (used in background jobs)
  # Note: ActiveJob serializes with string keys, so we only need to handle strings
  sig { params(hash: T.nilable(T::Hash[String, T.untyped])).void }
  def self.restore_chain!(hash)
    return if hash.blank?

    Thread.current[:automation_chain] = {
      depth: hash["depth"] || 0,
      executed_rule_ids: Set.new(hash["executed_rule_ids"] || []),
      origin_event_id: hash["origin_event_id"],
    }
  end

  # Clear chain context (call at end of job execution)
  sig { void }
  def self.clear_chain!
    Thread.current[:automation_chain] = nil
  end

  # Check if we're currently inside an automation chain
  sig { returns(T::Boolean) }
  def self.in_chain?
    chain = Thread.current[:automation_chain]
    chain.present? && chain[:depth] > 0
  end

  # Get the current chain depth
  sig { returns(Integer) }
  def self.chain_depth
    current_chain[:depth]
  end

  # Emit metrics for chain blocking (skip in test environment)
  sig { params(tenant_id: String, block_reason: String).void }
  def self.emit_chain_blocked_metric(tenant_id, block_reason)
    return if Rails.env.test?

    Yabeda.automations.chain_blocked_total.increment(
      { tenant_id: tenant_id, block_reason: block_reason },
      by: 1
    )
  end
  private_class_method :emit_chain_blocked_metric
end
