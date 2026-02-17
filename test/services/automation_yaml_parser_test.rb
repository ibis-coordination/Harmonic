# typed: false

require "test_helper"

class AutomationYamlParserTest < ActiveSupport::TestCase
  test "parses valid agent automation rule YAML" do
    yaml = <<~YAML
      name: "Respond to mentions"
      description: "When mentioned, respond appropriately"

      trigger:
        type: event
        event_type: note.created
        mention_filter: self

      task: |
        You were mentioned by {{event.actor.name}} in {{subject.path}}.
        Navigate there and respond.

      max_steps: 20
    YAML

    result = AutomationYamlParser.parse(yaml, ai_agent_id: "some-agent-id")

    assert result.success?
    assert_equal "Respond to mentions", result.attributes[:name]
    assert_equal "When mentioned, respond appropriately", result.attributes[:description]
    assert_equal "event", result.attributes[:trigger_type]
    assert_equal "note.created", result.attributes[:trigger_config]["event_type"]
    assert_equal "self", result.attributes[:trigger_config]["mention_filter"]
    assert_equal 20, result.attributes[:trigger_config]["max_steps"]
    assert_includes result.attributes[:actions]["task"], "You were mentioned"
  end

  test "parses valid general automation rule YAML" do
    yaml = <<~YAML
      name: "Notify on critical mass"
      description: "Post celebratory note"

      trigger:
        type: event
        event_type: commitment.critical_mass

      conditions:
        - field: "event.metadata.participant_count"
          operator: ">="
          value: 5

      actions:
        - type: internal_action
          action: create_note
          params:
            text: "{{subject.title}} reached critical mass!"
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert result.success?
    assert_equal "Notify on critical mass", result.attributes[:name]
    assert_equal "event", result.attributes[:trigger_type]
    assert_equal "commitment.critical_mass", result.attributes[:trigger_config]["event_type"]
    assert_equal 1, result.attributes[:conditions].length
    assert_equal "event.metadata.participant_count", result.attributes[:conditions][0]["field"]
    assert_equal 1, result.attributes[:actions].length
    assert_equal "internal_action", result.attributes[:actions][0]["type"]
  end

  test "parses schedule trigger YAML" do
    yaml = <<~YAML
      name: "Daily summary"

      trigger:
        type: schedule
        cron: "0 9 * * *"
        timezone: "America/Los_Angeles"

      task: |
        Review yesterday's activity and post a summary.
    YAML

    result = AutomationYamlParser.parse(yaml, ai_agent_id: "agent-id")

    assert result.success?
    assert_equal "schedule", result.attributes[:trigger_type]
    assert_equal "0 9 * * *", result.attributes[:trigger_config]["cron"]
    assert_equal "America/Los_Angeles", result.attributes[:trigger_config]["timezone"]
  end

  test "fails on invalid YAML syntax" do
    yaml = "name: 'Test\n  invalid: yaml: syntax"

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("Invalid YAML syntax") }
  end

  test "fails when name is missing" do
    yaml = <<~YAML
      trigger:
        type: event
        event_type: note.created
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert_includes result.errors, "name is required"
  end

  test "fails when trigger is missing" do
    yaml = <<~YAML
      name: "Test rule"
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert_includes result.errors, "trigger is required"
  end

  test "fails when trigger type is invalid" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: invalid_type
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("trigger.type must be one of") }
  end

  test "fails when event trigger missing event_type" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert_includes result.errors, "trigger.event_type is required for event triggers"
  end

  test "fails when schedule trigger missing cron" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: schedule
      task: "Do something"
    YAML

    result = AutomationYamlParser.parse(yaml, ai_agent_id: "agent-id")

    assert_not result.success?
    assert_includes result.errors, "trigger.cron is required for schedule triggers"
  end

  test "fails when mention_filter is invalid" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
        event_type: note.created
        mention_filter: invalid_filter
      task: "Do something"
    YAML

    result = AutomationYamlParser.parse(yaml, ai_agent_id: "agent-id")

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("trigger.mention_filter must be one of") }
  end

  test "fails when agent rule has actions instead of task" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
        event_type: note.created
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml, ai_agent_id: "agent-id")

    assert_not result.success?
    assert_includes result.errors, "task is required for agent automation rules"
    assert_includes result.errors, "actions should not be specified for agent rules (use task instead)"
  end

  test "fails when general rule missing actions" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
        event_type: note.created
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert_includes result.errors, "actions is required for automation rules"
  end

  test "validates condition operators" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
        event_type: note.created
      conditions:
        - field: "test"
          operator: "invalid_op"
          value: 5
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("conditions[0].operator must be one of") }
  end

  test "validates action types" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
        event_type: note.created
      actions:
        - type: invalid_type
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("actions[0].type must be one of") }
  end

  test "validates internal_action requires action field" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
        event_type: note.created
      actions:
        - type: internal_action
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("actions[0].action is required for internal_action type") }
  end

  test "validates webhook action requires url" do
    yaml = <<~YAML
      name: "Test rule"
      trigger:
        type: event
        event_type: note.created
      actions:
        - type: webhook
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("actions[0].url is required for webhook type") }
  end

  # === Webhook IP Restrictions ===

  test "parses webhook trigger with allowed_ips" do
    yaml = <<~YAML
      name: "IP Restricted Webhook"
      trigger:
        type: webhook
        allowed_ips:
          - "10.0.0.1"
          - "192.168.1.0/24"
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert result.success?
    assert_equal ["10.0.0.1", "192.168.1.0/24"], result.attributes[:trigger_config]["allowed_ips"]
  end

  test "validates allowed_ips must be an array" do
    yaml = <<~YAML
      name: "Invalid IP config"
      trigger:
        type: webhook
        allowed_ips: "10.0.0.1"
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("allowed_ips must be an array") }
  end

  test "validates allowed_ips entries must be valid IP addresses" do
    yaml = <<~YAML
      name: "Invalid IP"
      trigger:
        type: webhook
        allowed_ips:
          - "not-an-ip"
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("not a valid IP address") }
  end

  test "validates allowed_ips entries must be strings" do
    yaml = <<~YAML
      name: "Non-string IP"
      trigger:
        type: webhook
        allowed_ips:
          - 12345
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert_not result.success?
    assert result.errors.any? { |e| e.include?("must be a string") }
  end

  test "accepts valid CIDR notation" do
    yaml = <<~YAML
      name: "CIDR Webhook"
      trigger:
        type: webhook
        allowed_ips:
          - "10.0.0.0/8"
          - "172.16.0.0/12"
          - "192.168.0.0/16"
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert result.success?
    assert_equal 3, result.attributes[:trigger_config]["allowed_ips"].size
  end

  test "accepts IPv6 addresses" do
    yaml = <<~YAML
      name: "IPv6 Webhook"
      trigger:
        type: webhook
        allowed_ips:
          - "::1"
          - "2001:db8::/32"
      actions:
        - type: internal_action
          action: create_note
    YAML

    result = AutomationYamlParser.parse(yaml)

    assert result.success?
    assert_equal 2, result.attributes[:trigger_config]["allowed_ips"].size
  end
end
