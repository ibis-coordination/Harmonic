# typed: false

require "test_helper"

class AutomationInternalActionServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_studio_user
    # Ensure collective has an identity user
    @collective.create_identity_user! unless @collective.identity_user

    @rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Automation",
      trigger_type: "manual",
      trigger_config: {},
      actions: [
        { "type" => "internal_action", "action" => "create_note", "params" => { "text" => "Test note" } },
      ],
      created_by: @user
    )

    @run = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: @rule,
      trigger_source: "manual",
      status: "pending"
    )
  end

  test "SUPPORTED_ACTIONS contains expected actions" do
    assert_includes AutomationInternalActionService::SUPPORTED_ACTIONS, "create_note"
    assert_includes AutomationInternalActionService::SUPPORTED_ACTIONS, "create_decision"
    assert_includes AutomationInternalActionService::SUPPORTED_ACTIONS, "create_commitment"
  end

  test "execute returns error for unsupported action" do
    service = AutomationInternalActionService.new(@run)
    result = service.execute("unknown_action", {})

    assert_not result.success
    assert_includes result.error, "Unsupported action"
  end

  test "execute returns error when collective is nil" do
    # Create a user-level rule (no collective)
    user_rule = AutomationRule.create!(
      tenant: @tenant,
      collective: nil,
      user: @user,
      name: "User Automation",
      trigger_type: "manual",
      trigger_config: {},
      actions: [],
      created_by: @user
    )

    user_run = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: nil,
      automation_rule: user_rule,
      trigger_source: "manual",
      status: "pending"
    )

    service = AutomationInternalActionService.new(user_run)
    result = service.execute("create_note", { "text" => "Test" })

    assert_not result.success
    assert_includes result.error, "studio context"
  end

  test "execute creates note with automation context" do
    service = AutomationInternalActionService.new(@run)

    assert_difference "Note.count", 1 do
      result = service.execute("create_note", { "text" => "Automated note content" })

      # The result should be successful
      assert result.success, "Expected success but got error: #{result.error}"
    end

    # Verify the note was tracked via the join table
    note = Note.last
    tracked_run = AutomationRuleRunResource.run_for(note)
    assert_equal @run, tracked_run
    assert_equal @rule, tracked_run.automation_rule
  end

  test "created resources are linked to automation run via join table" do
    service = AutomationInternalActionService.new(@run)

    service.execute("create_note", { "text" => "Note 1" })
    service.execute("create_note", { "text" => "Note 2" })

    # Verify via the new helper methods
    assert_equal 2, @run.created_notes.size
    assert_equal 2, @run.automation_rule_run_resources.where(resource_type: "Note").count
  end

  test "AutomationRuleRunResource.run_for returns the automation run that created a resource" do
    service = AutomationInternalActionService.new(@run)
    service.execute("create_note", { "text" => "Test note" })

    note = Note.last
    run = AutomationRuleRunResource.run_for(note)

    assert_equal @run, run
  end

  test "AutomationRuleRunResource.run_for returns nil for resources not created by automation" do
    # Create a note directly, not through automation
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      text: "Manual note",
      created_by: @user
    )

    run = AutomationRuleRunResource.run_for(note)
    assert_nil run
  end
end
