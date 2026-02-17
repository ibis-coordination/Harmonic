# typed: false

require "test_helper"

class AutomationDispatcherTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_studio_user
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)

    # Add the AI agent to the tenant so it has a TenantUser (required for mentions)
    @tenant.add_user!(@ai_agent)

    # Clear any chain context from previous tests
    AutomationContext.clear_chain!
  end

  teardown do
    AutomationContext.clear_chain!
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

  test "rate limits agent rule execution at 3 per minute" do
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

  test "rate limits studio rule execution at 10 per minute" do
    # Create a studio rule (not an agent rule)
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Studio Webhook Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/hook" }],
      enabled: true
    )
    event = create_event_with_subject(event_type: "note.created")

    # Create 10 recent runs
    10.times do
      AutomationRuleRun.create!(
        tenant: @tenant,
        collective: @collective,
        automation_rule: rule,
        trigger_source: "event",
        status: "completed"
      )
    end

    # Should not queue an 11th execution
    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  end

  test "allows studio rule execution up to rate limit" do
    # Create a studio rule (not an agent rule)
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Studio Webhook Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/hook" }],
      enabled: true
    )
    event = create_event_with_subject(event_type: "note.created")

    # Create 9 recent runs (below limit of 10)
    9.times do
      AutomationRuleRun.create!(
        tenant: @tenant,
        collective: @collective,
        automation_rule: rule,
        trigger_source: "event",
        status: "completed"
      )
    end

    # Should allow a 10th execution
    assert_difference -> { AutomationRuleRun.count }, 1 do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  end

  # ===========================================================================
  # Tenant-level rate limiting tests
  # ===========================================================================

  test "rate limits at tenant level (100 per minute)" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Create 100 recent runs for this tenant using multiple rules
    # (to avoid hitting per-rule limits which are lower)
    100.times do |i|
      temp_rule = AutomationRule.create!(
        tenant: @tenant,
        ai_agent: @ai_agent,
        created_by: @user,
        name: "Temp Rule #{i}",
        trigger_type: "event",
        trigger_config: { "event_type" => "note.created" },
        actions: { "task" => "Do something" },
        enabled: true
      )
      AutomationRuleRun.create!(
        tenant: @tenant,
        automation_rule: temp_rule,
        trigger_source: "event",
        status: "completed"
      )
    end

    # Should not queue another execution - tenant limit reached
    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  end

  test "allows execution below tenant rate limit" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Create 99 recent runs using multiple rules
    # (to avoid hitting per-rule limits which are lower)
    99.times do |i|
      temp_rule = AutomationRule.create!(
        tenant: @tenant,
        ai_agent: @ai_agent,
        created_by: @user,
        name: "Temp Rule #{i}",
        trigger_type: "event",
        trigger_config: { "event_type" => "note.created" },
        actions: { "task" => "Do something" },
        enabled: true
      )
      AutomationRuleRun.create!(
        tenant: @tenant,
        automation_rule: temp_rule,
        trigger_source: "event",
        status: "completed"
      )
    end

    # Should allow one more - below tenant limit and rule hasn't been used
    assert_difference -> { AutomationRuleRun.count }, 1 do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  end

  test "tenant rate limit is independent per tenant" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Create another tenant with its own user, agent, and rules
    other_tenant = Tenant.create!(name: "Other Tenant", subdomain: "other-tenant")
    other_tenant.set_feature_flag!("ai_agents", true)
    other_user = create_user(name: "Other User")
    other_tenant.add_user!(other_user)
    other_agent = create_ai_agent(parent: other_user, name: "Other Agent")
    other_tenant.add_user!(other_agent)

    # Max out the other tenant's runs
    100.times do |i|
      other_rule = AutomationRule.create!(
        tenant: other_tenant,
        ai_agent: other_agent,
        created_by: other_user,
        name: "Other Rule #{i}",
        trigger_type: "event",
        trigger_config: { "event_type" => "note.created" },
        actions: { "task" => "Do something" },
        enabled: true
      )
      AutomationRuleRun.create!(
        tenant: other_tenant,
        automation_rule: other_rule,
        trigger_source: "event",
        status: "completed"
      )
    end

    # Current tenant (@tenant) should still be allowed since it has no runs
    assert_difference -> { AutomationRuleRun.count }, 1 do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  end

  # ===========================================================================
  # Chain protection tests
  # ===========================================================================

  test "blocks rule execution when chain depth exceeds limit" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Simulate chain at max depth by pre-populating the chain
    AutomationContext::MAX_CHAIN_DEPTH.times do |i|
      other_rule = AutomationRule.create!(
        tenant: @tenant,
        ai_agent: @ai_agent,
        created_by: @user,
        name: "Depth Rule #{i}",
        trigger_type: "event",
        trigger_config: { "event_type" => "note.created" },
        actions: { "task" => "Task" },
        enabled: true
      )
      AutomationContext.record_rule_execution!(other_rule, event)
    end

    # Should not queue execution when at max depth
    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  ensure
    AutomationContext.clear_chain!
  end

  test "blocks rule execution when same rule already in chain (loop prevention)" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Record this rule as already executed
    AutomationContext.record_rule_execution!(rule, event)

    # Should not queue execution - would be a loop
    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  ensure
    AutomationContext.clear_chain!
  end

  test "blocks rule execution when max rules per chain exceeded" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Create max rules and add them to the chain
    AutomationContext::MAX_RULES_PER_CHAIN.times do |i|
      other_rule = AutomationRule.create!(
        tenant: @tenant,
        ai_agent: @ai_agent,
        created_by: @user,
        name: "Fan-out Rule #{i}",
        trigger_type: "event",
        trigger_config: { "event_type" => "note.created" },
        actions: { "task" => "Task" },
        enabled: true
      )
      # Add to executed_rule_ids without incrementing depth
      AutomationContext.current_chain[:executed_rule_ids] << other_rule.id
    end

    # Should not queue execution when max rules reached
    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  ensure
    AutomationContext.clear_chain!
  end

  test "stores chain_metadata in automation run" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Set up some chain state
    first_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "First Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task" },
      enabled: true
    )
    AutomationContext.record_rule_execution!(first_rule, event)

    # Now queue execution of second rule
    AutomationDispatcher.queue_rule_execution(rule, event)

    run = AutomationRuleRun.last
    assert_equal 2, run.chain_metadata["depth"]
    assert_includes run.chain_metadata["executed_rule_ids"], first_rule.id
    assert_includes run.chain_metadata["executed_rule_ids"], rule.id
    assert_equal event.id, run.chain_metadata["origin_event_id"]
  ensure
    AutomationContext.clear_chain!
  end

  test "passes chain context to execution job" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Set up some chain state
    first_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "First Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task" },
      enabled: true
    )
    AutomationContext.record_rule_execution!(first_rule, event)

    assert_enqueued_with(job: AutomationRuleExecutionJob) do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end

    # Verify the enqueued job has chain args
    enqueued_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    job_args = enqueued_job[:args].first
    assert job_args["chain"].present?, "Expected chain to be present in job args"
    assert_equal 2, job_args["chain"]["depth"]
    assert_includes job_args["chain"]["executed_rule_ids"], first_rule.id
  ensure
    AutomationContext.clear_chain!
  end

  test "allows execution at depth below limit" do
    rule = create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    # Set up chain at depth 1 (below limit of 3)
    first_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "First Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task" },
      enabled: true
    )
    AutomationContext.record_rule_execution!(first_rule, event)

    # Should allow execution at depth 1
    assert_difference -> { AutomationRuleRun.count }, 1 do
      AutomationDispatcher.queue_rule_execution(rule, event)
    end
  ensure
    AutomationContext.clear_chain!
  end

  test "blocks two-rule mutual recursion (A triggers B, B would trigger A)" do
    event = create_event_with_subject(event_type: "note.created")

    # Rule A and Rule B both trigger on note.created
    rule_a = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Rule A",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task A" },
      enabled: true
    )
    rule_b = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Rule B",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task B" },
      enabled: true
    )

    # Simulate: Rule A executes first
    AutomationContext.record_rule_execution!(rule_a, event)
    assert_equal 1, AutomationContext.chain_depth

    # Rule B can execute (different rule, depth 1)
    assert AutomationContext.can_execute_rule?(rule_b)
    AutomationContext.record_rule_execution!(rule_b, event)
    assert_equal 2, AutomationContext.chain_depth

    # Now if B's action creates another event that would trigger A again,
    # A should be blocked because it's already in the chain
    assert_not AutomationContext.can_execute_rule?(rule_a),
      "Rule A should be blocked - already executed in this chain"

    # Verify queue_rule_execution also blocks it
    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.queue_rule_execution(rule_a, event)
    end
  ensure
    AutomationContext.clear_chain!
  end

  test "blocks three-rule cycle at depth limit (A -> B -> C -> A)" do
    event = create_event_with_subject(event_type: "note.created")

    rule_a = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Rule A",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task A" },
      enabled: true
    )
    rule_b = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Rule B",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task B" },
      enabled: true
    )
    rule_c = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Rule C",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task C" },
      enabled: true
    )

    # Simulate chain: A -> B -> C (hits depth 3, which is MAX_CHAIN_DEPTH)
    AutomationContext.record_rule_execution!(rule_a, event)
    AutomationContext.record_rule_execution!(rule_b, event)
    AutomationContext.record_rule_execution!(rule_c, event)
    assert_equal 3, AutomationContext.chain_depth

    # Rule A trying to execute again should be blocked by BOTH:
    # 1. Depth limit (3 >= MAX_CHAIN_DEPTH)
    # 2. Loop detection (A already in chain)
    assert_not AutomationContext.can_execute_rule?(rule_a)

    # Even a new rule D should be blocked by depth limit
    rule_d = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Rule D",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task D" },
      enabled: true
    )
    assert_not AutomationContext.can_execute_rule?(rule_d),
      "Rule D should be blocked by depth limit"
  ensure
    AutomationContext.clear_chain!
  end

  test "chain limits apply equally to studio and agent rules" do
    event = create_event_with_subject(event_type: "note.created")

    # Create a studio rule (has collective, uses webhook actions)
    studio_rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Studio Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com" }],
      enabled: true
    )

    # Create agent rules
    agent_rule_1 = create_rule_without_mention_filter
    agent_rule_2 = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Agent Rule 2",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Task" },
      enabled: true
    )

    # Mix of studio and agent rules in the chain
    AutomationContext.record_rule_execution!(studio_rule, event)
    AutomationContext.record_rule_execution!(agent_rule_1, event)
    AutomationContext.record_rule_execution!(agent_rule_2, event)

    # At depth 3, another rule (whether studio or agent) should be blocked
    another_studio_rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Another Studio Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/2" }],
      enabled: true
    )
    assert_not AutomationContext.can_execute_rule?(another_studio_rule),
      "Studio rule should be blocked at max depth even when mixed with agent rules"
  ensure
    AutomationContext.clear_chain!
  end

  # ===========================================================================
  # Event cascade tests (chain context flows through resource creation)
  # ===========================================================================

  test "chain context blocks cascaded event triggers" do
    # This tests the real scenario: an automation creates a Note, which fires
    # note.created event via the Tracked concern, which would trigger another rule.
    # The chain context should block this at the appropriate depth.

    # Create two rules that both trigger on note.created
    rule_1 = create_rule_without_mention_filter
    rule_2 = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Second note responder",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Respond to note" },
      enabled: true
    )

    # Simulate rule_1 executing and creating a note (which fires note.created)
    AutomationContext.record_rule_execution!(rule_1, nil)
    assert_equal 1, AutomationContext.chain_depth

    # Now when EventService.dispatch_to_handlers fires for the new note,
    # AutomationDispatcher.find_matching_rules will return rule_2 (matches note.created)
    # but rule_1 would not execute again (already in chain)

    # Create a new event (simulating the note.created from the automation's action)
    cascaded_event = create_event_with_subject(event_type: "note.created")

    # rule_2 should be allowed (different rule, depth < limit)
    assert AutomationContext.can_execute_rule?(rule_2)

    # rule_1 should be blocked (already executed)
    assert_not AutomationContext.can_execute_rule?(rule_1)

    # If rule_2 also executes...
    AutomationContext.record_rule_execution!(rule_2, cascaded_event)
    assert_equal 2, AutomationContext.chain_depth

    # And creates another note (another cascaded event), a third rule would still
    # be allowed but we're approaching the limit
    rule_3 = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Third responder",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Third task" },
      enabled: true
    )
    assert AutomationContext.can_execute_rule?(rule_3)
    AutomationContext.record_rule_execution!(rule_3, cascaded_event)
    assert_equal 3, AutomationContext.chain_depth

    # Now we're at max depth - no more rules can execute
    rule_4 = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Fourth responder",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Fourth task" },
      enabled: true
    )
    assert_not AutomationContext.can_execute_rule?(rule_4),
      "Fourth rule should be blocked by depth limit (3 >= MAX_CHAIN_DEPTH)"
  ensure
    AutomationContext.clear_chain!
  end

  test "EventService.dispatch_to_handlers respects chain context" do
    # This is an integration test verifying that when EventService fires an event,
    # the AutomationDispatcher receives the current chain context.

    rule = create_rule_without_mention_filter

    # Set up chain context simulating an automation already running
    AutomationContext::MAX_CHAIN_DEPTH.times do |i|
      blocking_rule = AutomationRule.create!(
        tenant: @tenant,
        ai_agent: @ai_agent,
        created_by: @user,
        name: "Blocking Rule #{i}",
        trigger_type: "event",
        trigger_config: { "event_type" => "note.created" },
        actions: { "task" => "Task" },
        enabled: true
      )
      AutomationContext.record_rule_execution!(blocking_rule, nil)
    end
    assert_equal AutomationContext::MAX_CHAIN_DEPTH, AutomationContext.chain_depth

    # Now create a note - this will trigger the Tracked concern's after_create_commit,
    # which calls EventService.record!, which calls AutomationDispatcher.dispatch
    assert_no_difference -> { AutomationRuleRun.count } do
      Note.create!(
        tenant: @tenant,
        collective: @collective,
        created_by: @user,
        text: "This note should not trigger any automations"
      )
    end
  ensure
    AutomationContext.clear_chain!
  end

  test "does not dispatch when ai_agents not enabled for tenant" do
    @tenant.set_feature_flag!("ai_agents", false)
    create_rule_without_mention_filter
    event = create_event_with_subject(event_type: "note.created")

    assert_no_difference -> { AutomationRuleRun.count } do
      AutomationDispatcher.dispatch(event)
    end
  end

  test "agent rule without collective triggers for events in any collective" do
    # Create a second collective
    other_collective = Collective.create!(
      tenant: @tenant,
      handle: "other-studio-#{SecureRandom.hex(4)}",
      name: "Other Studio",
      created_by: @user
    )

    # Create rule with no collective (agent rules don't have collective_id)
    rule = create_rule_without_mention_filter
    assert_nil rule.collective_id, "Agent rule should have nil collective_id"

    # Create event in a different collective
    note = Note.create!(
      tenant: @tenant,
      collective: other_collective,
      created_by: @user,
      text: "Note in other studio"
    )
    event = Event.create!(
      tenant: @tenant,
      collective: other_collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    # Rule should match even though event is in a different collective
    matching_rules = AutomationDispatcher.find_matching_rules(event)
    assert_includes matching_rules, rule
  end

  test "agent rule triggers regardless of current collective context" do
    # Create a second collective
    other_collective = Collective.create!(
      tenant: @tenant,
      handle: "context-studio-#{SecureRandom.hex(4)}",
      name: "Context Studio",
      created_by: @user
    )

    # Create rule with no collective
    rule = create_rule_without_mention_filter
    assert_nil rule.collective_id

    # Create event in original collective (with correct context)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "Note in original studio"
    )
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    # Now set thread-local context to the other collective (simulating
    # the scenario where the dispatcher is called in a different context)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: other_collective.handle)

    # Rule should still be found even with different collective context
    # because find_matching_rules uses tenant_scoped_only, not the default scope
    matching_rules = AutomationDispatcher.find_matching_rules(event)
    assert_includes matching_rules, rule
  ensure
    # Reset thread-local context
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
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
      collective: @collective,
      created_by: actor,
      text: text
    )

    Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: event_type,
      actor: actor,
      subject: note
    )
  end
end
