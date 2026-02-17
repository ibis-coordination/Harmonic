# typed: false

require "test_helper"

class AutomationRuleRunResourceTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_studio_user

    # Set thread context for queries that use default_scope
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Superagent.set_thread_context(@superagent)

    @rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Test Automation",
      trigger_type: "manual",
      trigger_config: {},
      actions: [],
      created_by: @user
    )

    @run = AutomationRuleRun.create!(
      tenant: @tenant,
      superagent: @superagent,
      automation_rule: @rule,
      trigger_source: "manual",
      status: "pending"
    )

    @note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      text: "Test note",
      created_by: @user
    )
  end

  # teardown handled by test_helper's global teardown

  test "validates resource_type inclusion for valid types" do
    # Test that all valid resource types are accepted
    valid_types = ["Note", "Decision", "Commitment", "Option", "Vote", "CommitmentParticipant", "NoteHistoryEvent"]
    valid_types.each do |type|
      resource = AutomationRuleRunResource.new(
        tenant: @tenant,
        automation_rule_run: @run,
        resource: @note, # Use Note for simplicity
        resource_superagent: @superagent,
        action_type: "create"
      )
      resource.write_attribute(:resource_type, type)
      # Don't check full validity since resource_id may not match the type,
      # just check that resource_type validation passes
      resource.valid?
      assert_not resource.errors[:resource_type].any?, "#{type} should be a valid resource_type"
    end
  end

  test "validates action_type inclusion" do
    resource = AutomationRuleRunResource.new(
      tenant: @tenant,
      automation_rule_run: @run,
      resource: @note,
      resource_superagent: @superagent,
      action_type: "create"
    )
    assert resource.valid?

    # Invalid action type
    resource.action_type = "invalid"
    assert_not resource.valid?
    assert_includes resource.errors[:action_type], "is not included in the list"
  end

  test "run_for returns the automation run that created a resource" do
    AutomationRuleRunResource.create!(
      tenant: @tenant,
      automation_rule_run: @run,
      resource: @note,
      resource_superagent: @superagent,
      action_type: "create"
    )

    found_run = AutomationRuleRunResource.run_for(@note)
    assert_equal @run, found_run
  end

  test "run_for returns nil for resources not created by automation" do
    other_note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      text: "Other note",
      created_by: @user
    )

    found_run = AutomationRuleRunResource.run_for(other_note)
    assert_nil found_run
  end

  test "run_for only finds create actions" do
    # Create an update record, not a create record
    AutomationRuleRunResource.create!(
      tenant: @tenant,
      automation_rule_run: @run,
      resource: @note,
      resource_superagent: @superagent,
      action_type: "update"
    )

    # run_for should not find update actions
    found_run = AutomationRuleRunResource.run_for(@note)
    assert_nil found_run
  end

  test "resource_unscoped loads resource across superagents" do
    resource_record = AutomationRuleRunResource.create!(
      tenant: @tenant,
      automation_rule_run: @run,
      resource: @note,
      resource_superagent: @superagent,
      action_type: "create"
    )

    # Even without the default scope, we should be able to load the resource
    loaded = resource_record.resource_unscoped
    assert_equal @note, loaded
  end

  test "display_title returns appropriate titles for different resource types" do
    resource_record = AutomationRuleRunResource.create!(
      tenant: @tenant,
      automation_rule_run: @run,
      resource: @note,
      resource_superagent: @superagent,
      action_type: "create"
    )

    title = resource_record.display_title(@note)
    assert_equal @note.title.truncate(60), title
  end

  test "validates resource_superagent matches resource" do
    other_superagent = Superagent.create!(
      tenant: @tenant,
      name: "Other Studio",
      handle: "other-studio-#{SecureRandom.hex(4)}",
      created_by: @user
    )

    resource = AutomationRuleRunResource.new(
      tenant: @tenant,
      automation_rule_run: @run,
      resource: @note,
      resource_superagent: other_superagent, # Wrong superagent!
      action_type: "create"
    )

    assert_not resource.valid?
    assert_includes resource.errors[:resource_superagent], "must match resource's superagent"
  end

  test "sets tenant_id from automation_rule_run" do
    resource = AutomationRuleRunResource.new(
      automation_rule_run: @run,
      resource: @note,
      resource_superagent: @superagent,
      action_type: "create"
    )

    resource.valid?
    assert_equal @tenant.id, resource.tenant_id
  end
end
