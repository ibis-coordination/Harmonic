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

    # Create a subagent for testing
    @subagent = User.create!(
      email: "capability-test-subagent@example.com",
      name: "Capability Test Subagent",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(@subagent)
    @superagent.add_user!(@subagent)
  end

  # Test: Non-subagent users have no restrictions
  test "non-subagent users have no restrictions" do
    assert CapabilityCheck.allowed?(@user, "create_note")
    assert CapabilityCheck.allowed?(@user, "vote")
    assert CapabilityCheck.allowed?(@user, "create_studio")
    assert CapabilityCheck.allowed?(@user, "update_profile")
  end

  # Test: Subagent with no capabilities configured can do all grantable actions
  test "subagent with no capabilities configured can do all grantable actions" do
    # No agent_configuration = all grantable actions allowed
    @subagent.update!(agent_configuration: nil)

    CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS.each do |action|
      assert CapabilityCheck.allowed?(@subagent, action),
        "Subagent with no config should be able to do #{action}"
    end
  end

  # Test: Subagent with empty capabilities array cannot do any grantable actions
  test "subagent with empty capabilities array cannot do any grantable actions" do
    @subagent.update!(agent_configuration: { "capabilities" => [] })

    CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS.each do |action|
      refute CapabilityCheck.allowed?(@subagent, action),
        "Subagent with empty capabilities should NOT be able to do #{action}"
    end

    # But infrastructure actions should still work
    CapabilityCheck::SUBAGENT_ALWAYS_ALLOWED.each do |action|
      assert CapabilityCheck.allowed?(@subagent, action),
        "Subagent should still be able to do infrastructure action #{action}"
    end
  end

  # Test: Subagent with capabilities configured can only do listed actions
  test "subagent with capabilities configured can only do listed actions" do
    @subagent.update!(agent_configuration: { "capabilities" => ["create_note", "add_comment"] })

    # Allowed actions
    assert CapabilityCheck.allowed?(@subagent, "create_note")
    assert CapabilityCheck.allowed?(@subagent, "add_comment")

    # Disallowed grantable actions
    refute CapabilityCheck.allowed?(@subagent, "vote")
    refute CapabilityCheck.allowed?(@subagent, "create_decision")
    refute CapabilityCheck.allowed?(@subagent, "create_commitment")
  end

  # Test: Subagent can always perform infrastructure actions
  test "subagent can always perform infrastructure actions" do
    # Even with restricted capabilities
    @subagent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    CapabilityCheck::SUBAGENT_ALWAYS_ALLOWED.each do |action|
      assert CapabilityCheck.allowed?(@subagent, action),
        "Subagent should always be able to do #{action}"
    end
  end

  # Test: Subagent cannot perform blocked actions regardless of config
  test "subagent cannot perform blocked actions regardless of config" do
    # Even with no restrictions
    @subagent.update!(agent_configuration: nil)

    CapabilityCheck::SUBAGENT_ALWAYS_BLOCKED.each do |action|
      refute CapabilityCheck.allowed?(@subagent, action),
        "Subagent should never be able to do #{action}"
    end

    # Even if explicitly listed in capabilities (would be invalid config)
    @subagent.update!(agent_configuration: { "capabilities" => ["create_studio", "update_profile"] })

    refute CapabilityCheck.allowed?(@subagent, "create_studio")
    refute CapabilityCheck.allowed?(@subagent, "update_profile")
  end

  # Test: allowed_actions returns infrastructure + configured for subagent
  test "allowed_actions returns infrastructure plus configured actions for subagent" do
    @subagent.update!(agent_configuration: { "capabilities" => ["create_note", "vote"] })

    allowed = CapabilityCheck.allowed_actions(@subagent)

    # Should include always-allowed
    CapabilityCheck::SUBAGENT_ALWAYS_ALLOWED.each do |action|
      assert_includes allowed, action
    end

    # Should include configured grantable actions
    assert_includes allowed, "create_note"
    assert_includes allowed, "vote"

    # Should not include non-configured grantable actions
    refute_includes allowed, "create_decision"
    refute_includes allowed, "create_commitment"
  end

  # Test: allowed_actions returns all ACTION_DEFINITIONS for non-subagent
  test "allowed_actions returns all actions for non-subagent" do
    allowed = CapabilityCheck.allowed_actions(@user)
    assert_equal ActionsHelper::ACTION_DEFINITIONS.keys, allowed
  end

  # Test: allowed_actions returns all grantable when no config
  test "allowed_actions returns all grantable actions when no config" do
    @subagent.update!(agent_configuration: nil)

    allowed = CapabilityCheck.allowed_actions(@subagent)

    # Should include always-allowed
    CapabilityCheck::SUBAGENT_ALWAYS_ALLOWED.each do |action|
      assert_includes allowed, action
    end

    # Should include all grantable actions
    CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS.each do |action|
      assert_includes allowed, action
    end
  end

  # Test: restricted_actions returns nil when no config
  test "restricted_actions returns nil when no config" do
    @subagent.update!(agent_configuration: nil)
    assert_nil CapabilityCheck.restricted_actions(@subagent)
  end

  # Test: restricted_actions returns nil for non-subagent
  test "restricted_actions returns nil for non-subagent" do
    assert_nil CapabilityCheck.restricted_actions(@user)
  end

  # Test: restricted_actions returns denied actions when configured
  test "restricted_actions returns denied actions when configured" do
    @subagent.update!(agent_configuration: { "capabilities" => ["create_note", "add_comment"] })

    restricted = CapabilityCheck.restricted_actions(@subagent)

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
    @subagent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    # Allowed capability
    assert ActionAuthorization.authorized?("create_note", @subagent, { studio: @superagent })

    # Disallowed capability (vote is grantable but not in config)
    refute ActionAuthorization.authorized?("vote", @subagent, { studio: @superagent })

    # Infrastructure action (always allowed)
    assert ActionAuthorization.authorized?("search", @subagent, {})

    # Blocked action (never allowed for subagents)
    refute ActionAuthorization.authorized?("create_studio", @subagent, {})
  end

  # Test: All grantable actions are valid action names
  test "all grantable actions are valid action names" do
    CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS.each do |action|
      assert ActionsHelper::ACTION_DEFINITIONS.key?(action),
        "Grantable action '#{action}' is not defined in ACTION_DEFINITIONS"
    end
  end

  # Test: All always-allowed actions are valid action names
  test "all always-allowed actions are valid action names" do
    CapabilityCheck::SUBAGENT_ALWAYS_ALLOWED.each do |action|
      assert ActionsHelper::ACTION_DEFINITIONS.key?(action),
        "Always-allowed action '#{action}' is not defined in ACTION_DEFINITIONS"
    end
  end

  # Test: All always-blocked actions are valid action names
  test "all always-blocked actions are valid action names" do
    CapabilityCheck::SUBAGENT_ALWAYS_BLOCKED.each do |action|
      assert ActionsHelper::ACTION_DEFINITIONS.key?(action),
        "Always-blocked action '#{action}' is not defined in ACTION_DEFINITIONS"
    end
  end

  # Test: No overlap between categories
  test "no overlap between action categories" do
    always_allowed = CapabilityCheck::SUBAGENT_ALWAYS_ALLOWED
    always_blocked = CapabilityCheck::SUBAGENT_ALWAYS_BLOCKED
    grantable = CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS

    assert_empty always_allowed & always_blocked,
      "Always-allowed and always-blocked should not overlap"
    assert_empty always_allowed & grantable,
      "Always-allowed and grantable should not overlap"
    assert_empty always_blocked & grantable,
      "Always-blocked and grantable should not overlap"
  end
end
