# typed: false

require "test_helper"

class AutomationRuleRunTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_studio_user
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(@ai_agent)

    @agent_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Agent Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Do something" },
      enabled: true
    )

    @studio_rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Studio Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com" }],
      enabled: true
    )
  end

  # === Callback: set_tenant_and_collective_from_rule ===

  test "automatically sets tenant_id from rule" do
    run = AutomationRuleRun.create!(
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert_equal @tenant.id, run.tenant_id
  end

  test "automatically sets collective_id from rule" do
    run = AutomationRuleRun.create!(
      automation_rule: @studio_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert_equal @collective.id, run.collective_id
  end

  test "collective_id is nil for agent rules without collective scope" do
    run = AutomationRuleRun.create!(
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert_nil run.collective_id
  end

  # === Validation: tenant_matches_rule ===

  test "validates tenant matches rule" do
    other_tenant = create_tenant(subdomain: "other")

    run = AutomationRuleRun.new(
      tenant: other_tenant,
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert_not run.valid?
    assert_includes run.errors[:tenant], "must match the automation rule's tenant"
  end

  test "allows tenant that matches rule" do
    run = AutomationRuleRun.new(
      tenant: @tenant,
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert run.valid?
  end

  # === Validation: collective_matches_rule ===

  test "validates collective matches rule" do
    other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other")

    run = AutomationRuleRun.new(
      tenant: @tenant,
      collective: other_collective,
      automation_rule: @studio_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert_not run.valid?
    assert_includes run.errors[:collective], "must match the automation rule's collective"
  end

  test "allows collective that matches rule" do
    run = AutomationRuleRun.new(
      tenant: @tenant,
      collective: @collective,
      automation_rule: @studio_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert run.valid?
  end

  test "allows nil collective for agent rules without collective scope" do
    run = AutomationRuleRun.new(
      tenant: @tenant,
      collective: nil,
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert run.valid?
  end

  test "rejects non-nil collective for agent rules without collective scope" do
    run = AutomationRuleRun.new(
      tenant: @tenant,
      collective: @collective,
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    assert_not run.valid?
    assert_includes run.errors[:collective], "must match the automation rule's collective"
  end

  # === Status methods ===

  test "pending? returns true when status is pending" do
    run = AutomationRuleRun.new(status: "pending")
    assert run.pending?
    assert_not run.running?
    assert_not run.completed?
    assert_not run.failed?
    assert_not run.skipped?
  end

  test "mark_running! transitions to running state" do
    run = AutomationRuleRun.create!(
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    run.mark_running!

    assert run.running?
    assert_not_nil run.started_at
  end

  test "mark_completed! transitions to completed state" do
    run = AutomationRuleRun.create!(
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    run.mark_completed!(executed_actions: [{ type: "test" }])

    assert run.completed?
    assert_not_nil run.completed_at
    assert_equal [{ "type" => "test" }], run.actions_executed
  end

  test "mark_failed! transitions to failed state with message" do
    run = AutomationRuleRun.create!(
      automation_rule: @agent_rule,
      trigger_source: "event",
      status: "pending"
    )

    run.mark_failed!("Something went wrong")

    assert run.failed?
    assert_not_nil run.completed_at
    assert_equal "Something went wrong", run.error_message
  end
end
