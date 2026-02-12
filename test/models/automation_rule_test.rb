# typed: false

require "test_helper"

class AutomationRuleTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    @ai_agent = create_ai_agent(parent: @user)
  end

  test "creates agent automation rule with valid attributes" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Respond to mentions",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" },
      actions: { "task" => "You were mentioned. Respond appropriately." }
    )

    assert rule.persisted?
    assert rule.agent_rule?
    assert_not rule.studio_rule?
    assert_not rule.user_rule?
  end

  test "creates studio automation rule with valid attributes" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      name: "Notify on critical mass",
      trigger_type: "event",
      trigger_config: { "event_type" => "commitment.critical_mass" },
      actions: [{ "type" => "internal_action", "action" => "create_note", "params" => { "text" => "Congrats!" } }]
    )

    assert rule.persisted?
    assert rule.studio_rule?
    assert_not rule.agent_rule?
    assert_not rule.user_rule?
  end

  test "validates trigger_type is required" do
    rule = AutomationRule.new(
      tenant: @tenant,
      created_by: @user,
      name: "Test rule"
    )

    assert_not rule.valid?
    assert_includes rule.errors[:trigger_type], "can't be blank"
  end

  test "validates trigger_type must be valid" do
    rule = AutomationRule.new(
      tenant: @tenant,
      created_by: @user,
      name: "Test rule",
      trigger_type: "invalid"
    )

    assert_not rule.valid?
    assert_includes rule.errors[:trigger_type], "is not included in the list"
  end

  test "validates ai_agent must be an AI agent" do
    rule = AutomationRule.new(
      tenant: @tenant,
      ai_agent: @user, # Regular user, not AI agent
      created_by: @user,
      name: "Test rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" }
    )

    assert_not rule.valid?
    assert_includes rule.errors[:ai_agent], "must be an AI agent"
  end

  test "validates only one scope type" do
    rule = AutomationRule.new(
      tenant: @tenant,
      superagent: @superagent,
      user: @user,
      created_by: @user,
      name: "Test rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" }
    )

    assert_not rule.valid?
    assert_includes rule.errors[:base], "Rule cannot be both studio-level and user-level"
  end

  test "generates webhook_path for webhook triggers" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      user: @user,
      name: "Webhook trigger",
      trigger_type: "webhook",
      trigger_config: {},
      actions: [{ "type" => "internal_action", "action" => "create_note" }]
    )

    assert rule.webhook_path.present?
    assert rule.webhook_secret.present?
    assert_equal 16, rule.webhook_path.length
  end

  test "event_type returns trigger config event_type" do
    rule = AutomationRule.new(
      trigger_config: { "event_type" => "note.created" }
    )

    assert_equal "note.created", rule.event_type
  end

  test "mention_filter returns trigger config mention_filter" do
    rule = AutomationRule.new(
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" }
    )

    assert_equal "self", rule.mention_filter
  end

  test "task_template returns task from actions for agent rules" do
    rule = AutomationRule.new(
      ai_agent: @ai_agent,
      actions: { "task" => "Do something" }
    )

    assert_equal "Do something", rule.task_template
  end

  test "increment_execution_count! increments count and sets last_executed_at" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      user: @user,
      name: "Test rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: []
    )

    assert_equal 0, rule.execution_count
    assert_nil rule.last_executed_at

    rule.increment_execution_count!

    assert_equal 1, rule.execution_count
    assert_not_nil rule.last_executed_at
  end

  test "enabled scope returns only enabled rules" do
    enabled_rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      user: @user,
      name: "Enabled",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      enabled: true,
      actions: []
    )

    disabled_rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      user: @user,
      name: "Disabled",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      enabled: false,
      actions: []
    )

    assert_includes AutomationRule.enabled, enabled_rule
    assert_not_includes AutomationRule.enabled, disabled_rule
  end

  test "for_event_type scope returns rules matching event type" do
    note_rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      user: @user,
      name: "Note rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: []
    )

    decision_rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      user: @user,
      name: "Decision rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "decision.created" },
      actions: []
    )

    assert_includes AutomationRule.for_event_type("note.created"), note_rule
    assert_not_includes AutomationRule.for_event_type("note.created"), decision_rule
  end
end
