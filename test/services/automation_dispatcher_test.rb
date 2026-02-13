# typed: false

require "test_helper"

class AutomationDispatcherTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)

    # Add the AI agent to the tenant so it has a TenantUser (required for mentions)
    @tenant.add_user!(@ai_agent)
  end

  test "finds matching rules for event type with mention filter" do
    rule = create_rule_with_mention_filter
    event = create_event_with_subject(event_type: "note.created", mentioned_user: @ai_agent)

    matching_rules = AutomationDispatcher.find_matching_rules(event)

    assert_includes matching_rules, rule
  end

  test "finds matching rules without mention filter" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    matching_rules = AutomationDispatcher.find_matching_rules(event)

    assert_includes matching_rules, rule
  end

  test "does not match disabled rules" do
    rule = create_rule_without_mention_filter
    rule.update!(enabled: false)
    event = create_event_with_subject(event_type: "note.created")

    matching_rules = AutomationDispatcher.find_matching_rules(event)

    assert_not_includes matching_rules, rule
  end

  test "does not match rules for different event types" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "decision.created")

    matching_rules = AutomationDispatcher.find_matching_rules(event)

    assert_not_includes matching_rules, rule
  end

  test "does not match when mention_filter is self and agent not mentioned" do
    rule = create_rule_with_mention_filter
    event = create_event_with_subject(event_type: "note.created", mentioned_user: nil)

    matching_rules = AutomationDispatcher.find_matching_rules(event)

    assert_not_includes matching_rules, rule
  end

  test "does not trigger when actor is the agent itself" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created", actor: @ai_agent)

    matching_rules = AutomationDispatcher.find_matching_rules(event)

    assert_not_includes matching_rules, rule
  end

  test "queues rule execution when rule matches" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    assert_difference -> { AutomationRuleRun.count }, 1 do
      assert_enqueued_with(job: AutomationRuleExecutionJob) do
        AutomationDispatcher.queue_rule_execution(rule, event)
      end
    end

    run = AutomationRuleRun.last
    assert_equal rule, run.automation_rule
    assert_equal event, run.triggered_by_event
    assert_equal "pending", run.status
    assert_equal "event", run.trigger_source
  end

  test "rate limits agent rule execution" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Create 3 recent runs
    3.times do
      AutomationRuleRun.create!(
        tenant: @tenant,
        automation_rule: rule,
        trigger_source: "event",
        status: "completed"
      )
    end

    # Should not queue a 4th execution
    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  end

  test "does not dispatch when ai_agents not enabled for tenant" do
    @tenant.set_feature_flag!("ai_agents", false)
    create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.dispatch(event)
    end
  end

  test "agent rule without superagent triggers for events in any superagent" do
    # Create a second superagent
    other_superagent = Superagent.create!(
      tenant: @tenant,
      handle: "other-studio-#{SecureRandom.hex(4)}",
      name: "Other Studio",
      created_by: @user
    )

    # Create rule with no superagent (agent rules don't have superagent_id)
    rule = create_rule_without_mention_filter
    assert_nil rule.superagent_id, "Agent rule should have nil superagent_id"

    # Create event in a different superagent
    note = Note.create!(
      tenant: @tenant,
      superagent: other_superagent,
      created_by: @user,
      text: "Note in other studio"
    )
    event = Event.create!(
      tenant: @tenant,
      superagent: other_superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    # Rule should match even though event is in a different superagent
    matching_rules = AutomationDispatcher.find_matching_rules(event)
    assert_includes matching_rules, rule
  end

  test "agent rule triggers regardless of current superagent context" do
    # Create a second superagent
    other_superagent = Superagent.create!(
      tenant: @tenant,
      handle: "context-studio-#{SecureRandom.hex(4)}",
      name: "Context Studio",
      created_by: @user
    )

    # Create rule with no superagent
    rule = create_rule_without_mention_filter
    assert_nil rule.superagent_id

    # Create event in original superagent (with correct context)
    note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      text: "Note in original studio"
    )
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    # Now set thread-local context to the other superagent (simulating
    # the scenario where the dispatcher is called in a different context)
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: other_superagent.handle)

    # Rule should still be found even with different superagent context
    # because find_matching_rules uses tenant_scoped_only, not the default scope
    matching_rules = AutomationDispatcher.find_matching_rules(event)
    assert_includes matching_rules, rule
  ensure
    # Reset thread-local context
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
  end

  private

  def create_rule_with_mention_filter
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Respond to mentions",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" },
      actions: { "task" => "You were mentioned. Respond." },
      enabled: true
    )
  end

  def create_rule_without_mention_filter
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Respond to notes",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "A note was created. Check it out." },
      enabled: true
    )
  end

  def create_event_with_subject(event_type:, mentioned_user: nil, actor: nil)
    actor ||= @user

    # Get the handle for the mentioned user
    agent_handle = nil
    if mentioned_user
      # The TenantUser is created by tenant.add_user!, find it using tenant_scoped_only
      tenant_user = TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: mentioned_user.id)
      agent_handle = tenant_user&.handle
    end

    text = mentioned_user && agent_handle ? "Hey @#{agent_handle} check this out" : "Just a regular note"

    note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: actor,
      text: text
    )

    Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: event_type,
      actor: actor,
      subject: note
    )
  end
end
