# typed: false

require "test_helper"

class AutomationFiringGateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    AutomationContext.clear_chain!
  end

  teardown do
    AutomationContext.clear_chain!
  end

  def create_rule(attrs = {})
    defaults = {
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Gate Test Rule",
      trigger_type: "manual",
      trigger_config: {},
      actions: [{ "type" => "webhook", "url" => "https://example.com" }],
    }
    AutomationRule.unscoped.create!(defaults.merge(attrs))
  end

  def fire(rule, source: "manual", event: nil, trigger_data: {})
    AutomationFiringGate.fire!(rule, source: source, event: event, trigger_data: trigger_data)
  end

  test "fire! creates a run with chain metadata and queues execution" do
    rule = create_rule

    result = nil
    assert_difference -> { AutomationRuleRun.unscoped.count }, 1 do
      assert_enqueued_with(job: AutomationRuleExecutionJob) do
        result = fire(rule, trigger_data: { "inputs" => {} })
      end
    end

    assert result.allowed?
    run = result.run
    assert_equal "manual", run.trigger_source
    assert_equal "pending", run.status
    assert run.chain_metadata.present?, "every fired run records chain metadata"
  end

  test "fire! refuses a disabled rule" do
    rule = create_rule(enabled: false)

    result = nil
    assert_no_difference -> { AutomationRuleRun.unscoped.count } do
      result = fire(rule)
    end

    assert_not result.allowed?
    assert_equal :disabled, result.refusal_reason
  end

  test "fire! refuses a soft-deleted rule regardless of enabled flag" do
    rule = create_rule
    rule.update_columns(deleted_at: Time.current)

    result = fire(rule)
    assert_equal :disabled, result.refusal_reason
  end

  test "fire! refuses when the rule's collective is not on a paid tier" do
    @tenant.set_feature_flag!("stripe_billing", true)
    free_collective = Collective.create!(
      tenant: @tenant, name: "Free #{SecureRandom.hex(2)}",
      handle: "free-#{SecureRandom.hex(4)}", created_by: @user, tier: Collective::TIER_FREE,
    )
    rule = create_rule(collective: free_collective)

    result = fire(rule)
    assert_equal :tier_locked, result.refusal_reason
  ensure
    @tenant.set_feature_flag!("stripe_billing", false)
  end

  test "fire! skips the tier gate for single-recipient events" do
    @tenant.set_feature_flag!("stripe_billing", true)
    free_collective = Collective.create!(
      tenant: @tenant, name: "Chat #{SecureRandom.hex(2)}",
      handle: "chat-#{SecureRandom.hex(4)}", created_by: @user, tier: Collective::TIER_FREE,
    )
    rule = create_rule(
      collective: nil,
      user: @user,
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" },
    )
    event = Event.create!(
      tenant: @tenant, collective: free_collective,
      event_type: "notifications.delivered", actor: @user, subject: free_collective,
    )

    result = fire(rule, source: "event", event: event)
    assert result.allowed?, "refused with #{result.refusal_reason.inspect}"
  ensure
    @tenant.set_feature_flag!("stripe_billing", false)
  end

  test "fire! refuses an event firing when the chain is exhausted" do
    rule = create_rule(trigger_type: "event", trigger_config: { "event_type" => "note.created" })
    AutomationContext.restore_chain!(
      "depth" => AutomationContext::MAX_CHAIN_DEPTH,
      "executed_rule_ids" => [],
      "origin_event_id" => nil,
    )

    result = fire(rule, source: "event")
    assert_equal :chain_blocked, result.refusal_reason
  end

  test "fire! from a non-event source starts a fresh chain" do
    rule = create_rule
    AutomationContext.restore_chain!(
      "depth" => AutomationContext::MAX_CHAIN_DEPTH,
      "executed_rule_ids" => [],
      "origin_event_id" => nil,
    )

    result = fire(rule)
    assert result.allowed?, "refused with #{result.refusal_reason.inspect}"
    assert_equal 1, result.run.chain_metadata["depth"]
  end

  test "fire! refuses when the per-rule rate limit is reached" do
    rule = create_rule
    10.times do
      AutomationRuleRun.unscoped.create!(
        tenant: @tenant, automation_rule: rule, trigger_source: "manual",
        status: "completed", trigger_data: {},
      )
    end

    result = fire(rule)
    assert_equal :rule_rate_limited, result.refusal_reason
  end

  test "fire! refuses when the tenant rate limit is reached" do
    rule = create_rule
    other_rule = create_rule(name: "Filler Rule")
    100.times do
      AutomationRuleRun.unscoped.create!(
        tenant: @tenant, automation_rule: other_rule, trigger_source: "manual",
        status: "completed", trigger_data: {},
      )
    end

    result = fire(rule)
    assert_equal :tenant_rate_limited, result.refusal_reason
  end
end
