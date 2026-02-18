# typed: false

require "test_helper"

class AutomationContextTest < ActiveSupport::TestCase
  teardown do
    # Clean up thread-local state after each test
    AutomationContext.clear!
    AutomationContext.clear_chain!
  end

  # ===========================================================================
  # Chain tracking tests
  # ===========================================================================

  test "new_chain returns fresh chain with zero depth" do
    chain = AutomationContext.new_chain

    assert_equal 0, chain[:depth]
    assert_empty chain[:executed_rule_ids]
    assert_nil chain[:origin_event_id]
  end

  test "current_chain initializes new chain if none exists" do
    AutomationContext.clear_chain!

    chain = AutomationContext.current_chain

    assert_equal 0, chain[:depth]
    assert_empty chain[:executed_rule_ids]
  end

  test "can_execute_rule? returns true for first rule in chain" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    assert AutomationContext.can_execute_rule?(rule)
  end

  test "can_execute_rule? returns false when depth exceeds limit" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    # Simulate chain at max depth
    AutomationContext::MAX_CHAIN_DEPTH.times do |i|
      other_rule = create_automation_rule(tenant: tenant, user: user, name: "Rule #{i}")
      AutomationContext.record_rule_execution!(other_rule, nil)
    end

    assert_not AutomationContext.can_execute_rule?(rule)
  end

  test "can_execute_rule? returns false when rule already executed (loop detection)" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    # Record this rule as already executed
    AutomationContext.record_rule_execution!(rule, nil)

    assert_not AutomationContext.can_execute_rule?(rule)
  end

  test "can_execute_rule? returns false when max rules per chain exceeded" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    # Execute max number of different rules
    AutomationContext::MAX_RULES_PER_CHAIN.times do |i|
      other_rule = create_automation_rule(tenant: tenant, user: user, name: "Rule #{i}")
      # Don't increment depth fully so we test rules limit, not depth limit
      chain = AutomationContext.current_chain
      chain[:executed_rule_ids] << other_rule.id
    end

    assert_not AutomationContext.can_execute_rule?(rule)
  end

  test "record_rule_execution! increments depth" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    assert_equal 0, AutomationContext.chain_depth

    AutomationContext.record_rule_execution!(rule, nil)

    assert_equal 1, AutomationContext.chain_depth
  end

  test "record_rule_execution! adds rule to executed set" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    AutomationContext.record_rule_execution!(rule, nil)

    assert_includes AutomationContext.current_chain[:executed_rule_ids], rule.id
  end

  test "record_rule_execution! sets origin_event_id on first execution" do
    tenant, collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)
    event = create_event(tenant: tenant, collective: collective, user: user)

    AutomationContext.record_rule_execution!(rule, event)

    assert_equal event.id, AutomationContext.current_chain[:origin_event_id]
  end

  test "record_rule_execution! preserves origin_event_id on subsequent executions" do
    tenant, collective, user = create_tenant_studio_user
    rule1 = create_automation_rule(tenant: tenant, user: user, name: "Rule 1")
    rule2 = create_automation_rule(tenant: tenant, user: user, name: "Rule 2")
    event1 = create_event(tenant: tenant, collective: collective, user: user)
    event2 = create_event(tenant: tenant, collective: collective, user: user)

    AutomationContext.record_rule_execution!(rule1, event1)
    AutomationContext.record_rule_execution!(rule2, event2)

    # Should still be the original event
    assert_equal event1.id, AutomationContext.current_chain[:origin_event_id]
  end

  test "chain_to_hash serializes chain state" do
    tenant, collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)
    event = create_event(tenant: tenant, collective: collective, user: user)

    AutomationContext.record_rule_execution!(rule, event)
    hash = AutomationContext.chain_to_hash

    assert_equal 1, hash["depth"]
    assert_includes hash["executed_rule_ids"], rule.id
    assert_equal event.id, hash["origin_event_id"]
  end

  test "restore_chain! restores chain state from hash" do
    rule_id = SecureRandom.uuid
    event_id = SecureRandom.uuid
    hash = {
      "depth" => 2,
      "executed_rule_ids" => [rule_id],
      "origin_event_id" => event_id,
    }

    AutomationContext.restore_chain!(hash)
    chain = AutomationContext.current_chain

    assert_equal 2, chain[:depth]
    assert_includes chain[:executed_rule_ids], rule_id
    assert_equal event_id, chain[:origin_event_id]
  end

  test "restore_chain! handles nil hash gracefully" do
    AutomationContext.restore_chain!(nil)

    # Should still be able to get current chain
    assert_equal 0, AutomationContext.chain_depth
  end

  test "restore_chain! handles empty hash gracefully" do
    AutomationContext.restore_chain!({})

    assert_equal 0, AutomationContext.chain_depth
  end

  test "clear_chain! resets chain state" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    AutomationContext.record_rule_execution!(rule, nil)
    assert_equal 1, AutomationContext.chain_depth

    AutomationContext.clear_chain!

    # New chain should be fresh
    assert_equal 0, AutomationContext.chain_depth
    assert_empty AutomationContext.current_chain[:executed_rule_ids]
  end

  test "in_chain? returns false when no chain" do
    AutomationContext.clear_chain!

    assert_not AutomationContext.in_chain?
  end

  test "in_chain? returns false when depth is 0" do
    AutomationContext.clear_chain!
    AutomationContext.current_chain # Initialize chain

    assert_not AutomationContext.in_chain?
  end

  test "in_chain? returns true when depth > 0" do
    tenant, _collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user)

    AutomationContext.record_rule_execution!(rule, nil)

    assert AutomationContext.in_chain?
  end

  # ===========================================================================
  # Run context tests (existing functionality)
  # ===========================================================================

  test "with_run sets current_run_id for duration of block" do
    tenant, collective, user = create_tenant_studio_user
    rule = create_automation_rule(tenant: tenant, user: user, collective: collective)
    run = AutomationRuleRun.create!(
      tenant: tenant,
      collective: collective,
      automation_rule: rule,
      trigger_source: "manual",
      status: "pending"
    )

    assert_nil AutomationContext.current_run_id

    result = AutomationContext.with_run(run) do
      assert_equal run.id, AutomationContext.current_run_id
      "block result"
    end

    assert_nil AutomationContext.current_run_id
    assert_equal "block result", result
  end

  private

  def create_automation_rule(tenant:, user:, name: "Test Rule", collective: nil)
    AutomationRule.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      name: name,
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com" }],
      enabled: true
    )
  end

  def create_event(tenant:, collective:, user:)
    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Test note"
    )
    Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "note.created",
      actor: user,
      subject: note
    )
  end
end
