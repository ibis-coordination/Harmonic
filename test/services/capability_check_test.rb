require "test_helper"

class CapabilityCheckTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )

    # Create a ai_agent for testing
    @ai_agent = User.create!(
      email: "capability-test-ai_agent@example.com",
      name: "Capability Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(@ai_agent)
    @superagent.add_user!(@ai_agent)
  end

  # Test: Non-ai_agent users have no restrictions
  test "non-ai_agent users have no restrictions" do
    assert CapabilityCheck.allowed?(@user, "create_note")
    assert CapabilityCheck.allowed?(@user, "vote")
    assert CapabilityCheck.allowed?(@user, "create_studio")
    assert CapabilityCheck.allowed?(@user, "update_profile")
  end

  # Test: AiAgent with no capabilities configured can do all grantable actions
  test "ai_agent with no capabilities configured can do all grantable actions" do
    # No agent_configuration = all grantable actions allowed
    @ai_agent.update!(agent_configuration: nil)

    CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS.each do |action|
      assert CapabilityCheck.allowed?(@ai_agent, action),
        "AiAgent with no config should be able to do #{action}"
    end
  end

  # Test: AiAgent with empty capabilities array cannot do any grantable actions
  test "ai_agent with empty capabilities array cannot do any grantable actions" do
    @ai_agent.update!(agent_configuration: { "capabilities" => [] })

    CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS.each do |action|
      refute CapabilityCheck.allowed?(@ai_agent, action),
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
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note", "add_comment"] })

    # Allowed actions
    assert CapabilityCheck.allowed?(@ai_agent, "create_note")
    assert CapabilityCheck.allowed?(@ai_agent, "add_comment")

    # Disallowed grantable actions
    refute CapabilityCheck.allowed?(@ai_agent, "vote")
    refute CapabilityCheck.allowed?(@ai_agent, "create_decision")
    refute CapabilityCheck.allowed?(@ai_agent, "create_commitment")
  end

  # Test: AiAgent can always perform infrastructure actions
  test "ai_agent can always perform infrastructure actions" do
    # Even with restricted capabilities
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED.each do |action|
      assert CapabilityCheck.allowed?(@ai_agent, action),
        "AiAgent should always be able to do #{action}"
    end
  end

  # Test: AiAgent cannot perform blocked actions regardless of config
  test "ai_agent cannot perform blocked actions regardless of config" do
    # Even with no restrictions
    @ai_agent.update!(agent_configuration: nil)

    CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED.each do |action|
      refute CapabilityCheck.allowed?(@ai_agent, action),
        "AiAgent should never be able to do #{action}"
    end

    # Even if explicitly listed in capabilities (would be invalid config)
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_studio", "update_profile"] })

    refute CapabilityCheck.allowed?(@ai_agent, "create_studio")
    refute CapabilityCheck.allowed?(@ai_agent, "update_profile")
  end

  # Test: allowed_actions returns infrastructure + configured for ai_agent
  test "allowed_actions returns infrastructure plus configured actions for ai_agent" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note", "vote"] })

    allowed = CapabilityCheck.allowed_actions(@ai_agent)

    # Should include always-allowed
    CapabilityCheck::AI_AGENT_ALWAYS_ALLOWED.each do |action|
      assert_includes allowed, action
    end

    # Should include configured grantable actions
    assert_includes allowed, "create_note"
    assert_includes allowed, "vote"

    # Should not include non-configured grantable actions
    refute_includes allowed, "create_decision"
    refute_includes allowed, "create_commitment"
  end

  # Test: allowed_actions returns all ACTION_DEFINITIONS for non-ai_agent
  test "allowed_actions returns all actions for non-ai_agent" do
    allowed = CapabilityCheck.allowed_actions(@user)
    assert_equal ActionsHelper::ACTION_DEFINITIONS.keys, allowed
  end

  # Test: allowed_actions returns all grantable when no config
  test "allowed_actions returns all grantable actions when no config" do
    @ai_agent.update!(agent_configuration: nil)

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

  # Test: restricted_actions returns nil when no config
  test "restricted_actions returns nil when no config" do
    @ai_agent.update!(agent_configuration: nil)
    assert_nil CapabilityCheck.restricted_actions(@ai_agent)
  end

  # Test: restricted_actions returns nil for non-ai_agent
  test "restricted_actions returns nil for non-ai_agent" do
    assert_nil CapabilityCheck.restricted_actions(@user)
  end

  # Test: restricted_actions returns denied actions when configured
  test "restricted_actions returns denied actions when configured" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note", "add_comment"] })

    restricted = CapabilityCheck.restricted_actions(@ai_agent)

    # Should not include configured actions
    refute_includes restricted, "create_note"
    refute_includes restricted, "add_comment"

    # Should include non-configured grantable actions
    assert_includes restricted, "vote"
    assert_includes restricted, "create_decision"
    assert_includes restricted, "create_commitment"
  end

  # Test: Integration with ActionAuthorization
  test "ActionAuthorization respects capability restrictions" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    # Allowed capability
    assert ActionAuthorization.authorized?("create_note", @ai_agent, { studio: @superagent })

    # Disallowed capability (vote is grantable but not in config)
    refute ActionAuthorization.authorized?("vote", @ai_agent, { studio: @superagent })

    # Infrastructure action (always allowed)
    assert ActionAuthorization.authorized?("search", @ai_agent, {})

    # Blocked action (never allowed for ai_agents)
    refute ActionAuthorization.authorized?("create_studio", @ai_agent, {})
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
end
