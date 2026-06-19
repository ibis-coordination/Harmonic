require "test_helper"

class CapabilityCheckTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )

    # Create a ai_agent for testing
    @ai_agent = User.create!(
      email: "capability-test-ai_agent@example.com",
      name: "Capability Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
  end

  # Test: Non-ai_agent users have no restrictions
  test "non-ai_agent users have no restrictions" do
    assert CapabilityCheck.allowed?(@user, "create_note")
    assert CapabilityCheck.allowed?(@user, "vote")
    assert CapabilityCheck.allowed?(@user, "create_collective")
    assert CapabilityCheck.allowed?(@user, "update_profile")
  end

  # Test: AiAgent with no capabilities configured can do all grantable actions
  test "ai_agent with no capabilities configured can do all grantable actions" do
    # No agent_configuration = all grantable actions allowed
    @ai_agent.update_columns(agent_configuration: nil)

    CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS.each do |action|
      assert CapabilityCheck.allowed?(@ai_agent, action),
             "AiAgent with no config should be able to do #{action}"
    end
  end

  # Test: AiAgent with empty capabilities array cannot do any grantable actions
  test "ai_agent with empty capabilities array cannot do any grantable actions" do
    @ai_agent.update_columns(agent_configuration: { "capabilities" => [] })

    CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS.each do |action|
      assert_not CapabilityCheck.allowed?(@ai_agent, action),
                 "AiAgent with empty capabilities should NOT be able to do #{action}"
    end

    # But infrastructure actions should still work
    CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED.each do |action|
      assert CapabilityCheck.allowed?(@ai_agent, action),
             "AiAgent should still be able to do infrastructure action #{action}"
    end
  end

  # Test: AiAgent with capabilities configured can only do listed actions
  test "ai_agent with capabilities configured can only do listed actions" do
    @ai_agent.update_columns(agent_configuration: { "capabilities" => ["create_note", "add_comment"] })

    # Allowed actions
    assert CapabilityCheck.allowed?(@ai_agent, "create_note")
    assert CapabilityCheck.allowed?(@ai_agent, "add_comment")

    # Disallowed grantable actions
    assert_not CapabilityCheck.allowed?(@ai_agent, "vote")
    assert_not CapabilityCheck.allowed?(@ai_agent, "create_decision")
    assert_not CapabilityCheck.allowed?(@ai_agent, "create_commitment")
  end

  # Test: AiAgent can always perform infrastructure actions
  test "ai_agent can always perform infrastructure actions" do
    # Even with restricted capabilities
    @ai_agent.update_columns(agent_configuration: { "capabilities" => ["create_note"] })

    CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED.each do |action|
      assert CapabilityCheck.allowed?(@ai_agent, action),
             "AiAgent should always be able to do #{action}"
    end
  end

  # Test: AiAgent cannot perform blocked actions regardless of config
  test "ai_agent cannot perform blocked actions regardless of config" do
    # Even with no restrictions
    @ai_agent.update_columns(agent_configuration: nil)

    CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED.each do |action|
      assert_not CapabilityCheck.allowed?(@ai_agent, action),
                 "AiAgent should never be able to do #{action}"
    end

    # Even if explicitly listed in capabilities (would be invalid config)
    @ai_agent.update_columns(agent_configuration: { "capabilities" => ["create_collective", "update_profile"] })

    assert_not CapabilityCheck.allowed?(@ai_agent, "create_collective")
    assert_not CapabilityCheck.allowed?(@ai_agent, "update_profile")
  end

  # Test: allowed_actions returns infrastructure + configured for ai_agent
  test "allowed_actions returns infrastructure plus configured actions for ai_agent" do
    @ai_agent.update_columns(agent_configuration: { "capabilities" => ["create_note", "vote"] })

    allowed = CapabilityCheck.allowed_actions(@ai_agent)

    # Should include always-allowed
    CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED.each do |action|
      assert_includes allowed, action
    end

    # Should include configured grantable actions
    assert_includes allowed, "create_note"
    assert_includes allowed, "vote"

    # Should not include non-configured grantable actions
    assert_not_includes allowed, "create_decision"
    assert_not_includes allowed, "create_commitment"
  end

  # Test: allowed_actions returns all ACTION_DEFINITIONS for non-ai_agent
  test "allowed_actions returns all actions for non-ai_agent" do
    allowed = CapabilityCheck.allowed_actions(@user)
    assert_equal ActionsHelper::ACTION_DEFINITIONS.keys, allowed
  end

  # Test: allowed_actions returns all grantable when no config
  test "allowed_actions returns all grantable actions when no config" do
    @ai_agent.update_columns(agent_configuration: nil)

    allowed = CapabilityCheck.allowed_actions(@ai_agent)

    # Should include always-allowed
    CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED.each do |action|
      assert_includes allowed, action
    end

    # Should include all grantable actions
    CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS.each do |action|
      assert_includes allowed, action
    end
  end

  # Test: Integration with ActionAuthorization
  test "ActionAuthorization respects capability restrictions" do
    @ai_agent.update_columns(agent_configuration: { "capabilities" => ["create_note"] })

    # Allowed capability
    assert ActionAuthorization.authorized?("create_note", @ai_agent, { collective: @collective })

    # Disallowed capability (vote is grantable but not in config)
    assert_not ActionAuthorization.authorized?("vote", @ai_agent, { collective: @collective })

    # Blocked action (never allowed for ai_agents)
    assert_not ActionAuthorization.authorized?("create_collective", @ai_agent, {})
  end

  # Test: All grantable actions are valid action names
  test "all grantable actions are valid action names" do
    CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS.each do |action|
      assert ActionsHelper::ACTION_DEFINITIONS.key?(action),
             "Grantable action '#{action}' is not defined in ACTION_DEFINITIONS"
    end
  end

  # Test: All always-allowed actions are valid action names
  test "all always-allowed actions are valid action names" do
    CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED.each do |action|
      assert ActionsHelper::ACTION_DEFINITIONS.key?(action),
             "Always-allowed action '#{action}' is not defined in ACTION_DEFINITIONS"
    end
  end

  # Test: All always-blocked actions are valid action names
  test "all always-blocked actions are valid action names" do
    CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED.each do |action|
      assert ActionsHelper::ACTION_DEFINITIONS.key?(action),
             "Always-blocked action '#{action}' is not defined in ACTION_DEFINITIONS"
    end
  end

  # Test: No overlap between categories
  test "no overlap between action categories" do
    always_allowed = CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED
    always_blocked = CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED
    grantable = CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS

    assert_empty always_allowed & always_blocked,
                 "Always-allowed and always-blocked should not overlap"
    assert_empty always_allowed & grantable,
                 "Always-allowed and grantable should not overlap"
    assert_empty always_blocked & grantable,
                 "Always-blocked and grantable should not overlap"
  end

  # Test: every defined action is categorized in exactly one list.
  #
  # This forces new actions to declare their agent policy. Before this test,
  # an action added to ACTION_DEFINITIONS without a corresponding entry in
  # ALLOWED/BLOCKED/GRANTABLE would default to "allowed for any agent whose
  # owner hasn't explicitly narrowed capabilities" — a fail-open default.
  # The test + the fail-closed default in `allowed?` together close that gap.
  test "every defined action is in exactly one capability list" do
    always_allowed = CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED
    always_blocked = CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED
    grantable = CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS

    uncategorized = ActionsHelper::ACTION_DEFINITIONS.keys - always_allowed - always_blocked - grantable
    assert_empty uncategorized,
                 "Actions defined in ACTION_DEFINITIONS but not placed in any capability list: " \
                 "#{uncategorized.inspect}. Add each to AI_AGENT_ALWAYS_ALLOWED (infrastructure), " \
                 "AI_AGENT_ALWAYS_BLOCKED (human-only), or AI_AGENT_GRANTABLE_ACTIONS (owner-configurable)."
  end

  # Test: every CONTROLLER_ACTION_MAP value is a valid capability action name
  test "every CONTROLLER_ACTION_MAP value is a valid capability action name" do
    all_actions = CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED +
                  CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED +
                  CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS

    invalid = ActionCapabilityCheck::CONTROLLER_ACTION_MAP.select do |_key, action|
      !all_actions.include?(action)
    end

    assert_empty invalid,
                 "CONTROLLER_ACTION_MAP entries map to unknown capability actions: " \
                 "#{invalid.inspect}. Each value must appear in AI_AGENT_ALWAYS_ALLOWED, " \
                 "AI_AGENT_ALWAYS_BLOCKED, or AI_AGENT_GRANTABLE_ACTIONS."
  end

  # Test: fail-closed for uncategorized actions even with nil capabilities.
  test "ai_agent with nil capabilities is denied an uncategorized action" do
    @ai_agent.update_columns(agent_configuration: nil)

    # A hypothetical action that isn't in any list. The system must not allow it
    # just because capabilities is unset.
    assert_not CapabilityCheck.allowed?(@ai_agent, "hypothetical_new_dangerous_action"),
               "Uncategorized actions must fail closed, not allowed by default"
  end

  # AI_AGENT_GRANTABLE_GROUPS is the source of truth for how the agent-creation
  # form presents grantable capabilities to humans. These tests enforce that the
  # groups stay in lockstep with AI_AGENT_GRANTABLE_ACTIONS — every action shows
  # up in exactly one group, no group lists an action that isn't grantable, and
  # every group is properly described. If you add an action to
  # AI_AGENT_GRANTABLE_ACTIONS, these tests will fail until you add it to a
  # group; if you remove one, they'll fail until you remove it from its group.

  test "every grantable action appears in exactly one group" do
    grouped_actions = CapabilityCheck::AI_AGENT_GRANTABLE_GROUPS.flat_map { |g| g[:actions] }

    missing = CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS - grouped_actions
    assert_empty missing,
                 "Actions in AI_AGENT_GRANTABLE_ACTIONS are missing from AI_AGENT_GRANTABLE_GROUPS — " \
                 "the agent-creation form won't expose them. Add them to a group: #{missing.inspect}"

    extras = grouped_actions - CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS
    assert_empty extras,
                 "AI_AGENT_GRANTABLE_GROUPS lists actions that aren't in AI_AGENT_GRANTABLE_ACTIONS. " \
                 "The form would render checkboxes the server will silently drop: #{extras.inspect}"

    duplicates = grouped_actions.tally.select { |_, count| count > 1 }.keys
    assert_empty duplicates,
                 "Actions appear in multiple groups; pick one home for each: #{duplicates.inspect}"
  end

  test "every group has a name and description" do
    CapabilityCheck::AI_AGENT_GRANTABLE_GROUPS.each do |group|
      assert group[:name].is_a?(String) && group[:name].present?,
             "Group missing name: #{group.inspect}"
      assert group[:description].is_a?(String) && group[:description].present?,
             "Group missing description: #{group.inspect}"
      assert group[:actions].is_a?(Array) && group[:actions].any?,
             "Group has no actions: #{group.inspect}"
    end
  end
end
