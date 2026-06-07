# typed: false

require "test_helper"

class AutomationRuleTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
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
    assert_not rule.collective_rule?
    assert_not rule.user_rule?
  end

  test "creates collective automation rule with valid attributes" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Notify on critical mass",
      trigger_type: "event",
      trigger_config: { "event_type" => "commitment.critical_mass" },
      actions: [{ "type" => "internal_action", "action" => "create_note", "params" => { "text" => "Congrats!" } }]
    )

    assert rule.persisted?
    assert rule.collective_rule?
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
      collective: @collective,
      user: @user,
      created_by: @user,
      name: "Test rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" }
    )

    assert_not rule.valid?
    assert_includes rule.errors[:base], "Rule cannot be both collective-level and user-level"
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

  test "generates webhook_secret for all trigger types (for signing outgoing webhooks)" do
    # Event trigger should also get a secret for signing outgoing webhook actions
    event_rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      collective: @collective,
      name: "Event trigger with webhook action",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/hook", "body" => {} }]
    )

    assert event_rule.webhook_secret.present?, "Event trigger should have webhook_secret for signing"

    # Schedule trigger should also get a secret
    schedule_rule = AutomationRule.create!(
      tenant: @tenant,
      created_by: @user,
      collective: @collective,
      name: "Scheduled webhook",
      trigger_type: "schedule",
      trigger_config: { "cron" => "0 9 * * *" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/hook", "body" => {} }]
    )

    assert schedule_rule.webhook_secret.present?, "Schedule trigger should have webhook_secret for signing"
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

  test "next_scheduled_run returns nil for event trigger type" do
    rule = AutomationRule.new(
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      enabled: true
    )

    assert_nil rule.next_scheduled_run
  end

  test "next_scheduled_run returns nil for disabled schedule rules" do
    rule = AutomationRule.new(
      trigger_type: "schedule",
      trigger_config: { "cron" => "0 9 * * *" },
      enabled: false
    )

    assert_nil rule.next_scheduled_run
  end

  test "next_scheduled_run returns future time for enabled schedule rules" do
    travel_to Time.zone.parse("2024-06-15 08:30:00 UTC") do
      rule = AutomationRule.new(
        trigger_type: "schedule",
        trigger_config: { "cron" => "0 9 * * *", "timezone" => "UTC" },
        enabled: true
      )

      next_run = rule.next_scheduled_run
      assert_not_nil next_run
      assert_equal Time.zone.parse("2024-06-15 09:00:00 UTC").to_i, next_run.to_i
    end
  end

  test "next_scheduled_run respects configured timezone" do
    # June 15, 2024 at 12:30 UTC = 8:30am Eastern (EDT, UTC-4)
    # Next 9am Eastern = 1pm UTC
    travel_to Time.zone.parse("2024-06-15 12:30:00 UTC") do
      rule = AutomationRule.new(
        trigger_type: "schedule",
        trigger_config: { "cron" => "0 9 * * *", "timezone" => "America/New_York" },
        enabled: true
      )

      next_run = rule.next_scheduled_run
      assert_not_nil next_run
      # 9am Eastern (EDT) on June 15 = 1pm UTC
      assert_equal Time.zone.parse("2024-06-15 13:00:00 UTC").to_i, next_run.to_i
    end
  end

  test "next_scheduled_run returns nil for invalid cron expression" do
    rule = AutomationRule.new(
      trigger_type: "schedule",
      trigger_config: { "cron" => "invalid cron" },
      enabled: true
    )

    assert_nil rule.next_scheduled_run
  end

  # === IP Restriction Tests ===

  test "allowed_ips returns empty array when not configured" do
    rule = AutomationRule.new(trigger_config: {})
    assert_equal [], rule.allowed_ips
  end

  test "allowed_ips returns configured IPs" do
    rule = AutomationRule.new(
      trigger_config: { "allowed_ips" => ["10.0.0.1", "192.168.1.0/24"] }
    )
    assert_equal ["10.0.0.1", "192.168.1.0/24"], rule.allowed_ips
  end

  test "ip_restricted? returns false when no IPs configured" do
    rule = AutomationRule.new(trigger_config: {})
    assert_not rule.ip_restricted?
  end

  test "ip_restricted? returns true when IPs are configured" do
    rule = AutomationRule.new(
      trigger_config: { "allowed_ips" => ["10.0.0.1"] }
    )
    assert rule.ip_restricted?
  end

  test "ip_allowed? returns true when no restrictions" do
    rule = AutomationRule.new(trigger_config: {})
    assert rule.ip_allowed?("1.2.3.4")
  end

  test "ip_allowed? returns true for exact IP match" do
    rule = AutomationRule.new(
      trigger_config: { "allowed_ips" => ["10.0.0.1", "10.0.0.2"] }
    )
    assert rule.ip_allowed?("10.0.0.1")
    assert rule.ip_allowed?("10.0.0.2")
    assert_not rule.ip_allowed?("10.0.0.3")
  end

  test "ip_allowed? returns true for IP within CIDR range" do
    rule = AutomationRule.new(
      trigger_config: { "allowed_ips" => ["192.168.1.0/24"] }
    )
    assert rule.ip_allowed?("192.168.1.1")
    assert rule.ip_allowed?("192.168.1.254")
    assert_not rule.ip_allowed?("192.168.2.1")
  end

  test "ip_allowed? handles IPv6 addresses" do
    rule = AutomationRule.new(
      trigger_config: { "allowed_ips" => ["::1", "2001:db8::/32"] }
    )
    assert rule.ip_allowed?("::1")
    assert rule.ip_allowed?("2001:db8::1")
    assert_not rule.ip_allowed?("2001:db9::1")
  end

  test "ip_allowed? returns false for invalid client IP" do
    rule = AutomationRule.new(
      trigger_config: { "allowed_ips" => ["10.0.0.1"] }
    )
    assert_not rule.ip_allowed?("not-an-ip")
  end

  test "ip_allowed? handles invalid allowed IP gracefully" do
    rule = AutomationRule.new(
      trigger_config: { "allowed_ips" => ["not-an-ip", "10.0.0.1"] }
    )
    # Should still match the valid IP
    assert rule.ip_allowed?("10.0.0.1")
    assert_not rule.ip_allowed?("10.0.0.2")
  end

  # === Internal vs external agent rule predicates ===

  test "internal_agent_rule? is true for internal-mode agent" do
    internal_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "internal" })
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: internal_agent,
      created_by: @user,
      name: "Internal rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Do it" }
    )

    assert rule.internal_agent_rule?
  end

  test "internal_agent_rule? is false for external-mode agent" do
    external_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "external" })
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "External rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" },
      actions: { "webhook_url" => "https://example.com/hook" }
    )

    assert_not rule.internal_agent_rule?
  end

  test "internal_agent_rule? is false for collective rules" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Collective rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "internal_action", "action" => "create_note" }]
    )

    assert_not rule.internal_agent_rule?
  end

  # === Conditional validations ===

  test "internal-agent rule requires actions to include a task" do
    internal_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "internal" })
    rule = AutomationRule.new(
      tenant: @tenant,
      ai_agent: internal_agent,
      created_by: @user,
      name: "No task",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: {}
    )

    assert_not rule.valid?
    assert_includes rule.errors[:actions], "must include a task"
  end

  test "internal-agent rule does not require webhook_url" do
    # Sanity: internal-agent rule with task is valid even without a webhook URL.
    internal_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "internal" })
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: internal_agent,
      created_by: @user,
      name: "Internal",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Do it" }
    )
    assert rule.persisted?
  end

  # === Notification-webhook rule predicate ===

  test "notification_webhook_rule? is true for agent-owned rule with webhook_url" do
    external_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "external" })
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "Agent webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" }
    )
    assert rule.notification_webhook_rule?
  end

  test "notification_webhook_rule? is true for user-owned rule with webhook_url" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "User webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" }
    )
    assert rule.notification_webhook_rule?
  end

  test "notification_webhook_rule? is false for collective-only rule even with webhook_url shape" do
    rule = AutomationRule.new(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Collective with webhook shape",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "webhook_url" => "https://example.com/hook" }
    )
    assert_not rule.notification_webhook_rule?
  end

  test "notification_webhook_rule? is false for rules without webhook_url" do
    rule = AutomationRule.new(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "User rule no webhook",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "internal_action", "action" => "create_note" }]
    )
    assert_not rule.notification_webhook_rule?
  end

  # === Shape-mixing validation ===

  test "collective-only rule cannot use notification-webhook shape" do
    rule = AutomationRule.new(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Collective with webhook shape",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "webhook_url" => "https://example.com/hook" }
    )
    assert_not rule.valid?
    assert_includes rule.errors[:actions], "collective-only rules cannot use notification-webhook shape"
  end

  # === Single-notification-webhook-per-user validation ===

  test "second notification webhook for the same agent is rejected" do
    external_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "external" })
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "First webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/first" }
    )
    second = AutomationRule.new(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "Second webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/second" }
    )
    assert_not second.valid?
    assert_includes second.errors[:base].join(" "), "already has a notification webhook"
  end

  test "second notification webhook for the same user is rejected" do
    AutomationRule.create!(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "First user webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/first" }
    )
    second = AutomationRule.new(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "Second user webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/second" }
    )
    assert_not second.valid?
    assert_includes second.errors[:base].join(" "), "already has a notification webhook"
  end

  test "DB partial unique index rejects a second webhook rule that bypasses validation" do
    external_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "external" })
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "First",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/first" }
    )
    second = AutomationRule.new(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "Second",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/second" }
    )

    # Simulate a race that lost the validation check: save with validate: false.
    assert_raises(ActiveRecord::RecordNotUnique) do
      second.save(validate: false)
    end
  end

  test "updating the existing webhook rule does not trigger the single-webhook validation" do
    external_agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "external" })
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "Webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/first" }
    )
    rule.actions = rule.actions.merge("webhook_url" => "https://example.com/updated")
    assert rule.valid?, rule.errors.full_messages.to_s
  end
end
