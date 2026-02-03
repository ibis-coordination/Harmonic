require "test_helper"

class SubagentTaskRunResourceTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle,
    )

    @subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(@subagent)
    @superagent.add_user!(@subagent)

    @task_run = SubagentTaskRun.create!(
      tenant: @tenant,
      subagent: @subagent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "running",
    )
  end

  # === Validation Tests ===

  test "resource with Note type is valid" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.new(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )
    assert resource.valid?, "Expected Note resource to be valid, but got: #{resource.errors.full_messages}"
  end

  test "resource with Decision type is valid" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.new(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: decision,
      resource_superagent: @superagent,
      action_type: "create",
    )
    assert resource.valid?, "Expected Decision resource to be valid, but got: #{resource.errors.full_messages}"
  end

  test "invalid resource type is rejected" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.new(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource_type: "User",  # User is not an allowed resource type
      resource_id: note.id,
      resource_superagent: @superagent,
      action_type: "create",
    )
    assert_not resource.valid?
    assert_includes resource.errors[:resource_type], "is not included in the list"
  end

  test "valid action types are accepted" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    %w[create update confirm add_options vote commit].each do |action_type|
      resource = SubagentTaskRunResource.new(
        tenant: @tenant,
        subagent_task_run: @task_run,
        resource: note,
        resource_superagent: @superagent,
        action_type: action_type,
      )
      assert resource.valid?, "Expected #{action_type} to be valid, but got: #{resource.errors.full_messages}"
    end
  end

  test "invalid action type is rejected" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.new(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "invalid_action",
    )
    assert_not resource.valid?
    assert_includes resource.errors[:action_type], "is not included in the list"
  end

  test "resource_superagent must match resource superagent" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    other_superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "other-studio-#{SecureRandom.hex(4)}")

    resource = SubagentTaskRunResource.new(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: other_superagent,
      action_type: "create",
    )
    assert_not resource.valid?
    assert_includes resource.errors[:resource_superagent], "must match resource's superagent"
  end

  # === Association Tests ===

  test "belongs to subagent_task_run" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )
    assert_equal @task_run, resource.subagent_task_run
  end

  test "task run has many resources" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )
    SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: decision,
      resource_superagent: @superagent,
      action_type: "create",
    )

    assert_equal 2, @task_run.subagent_task_run_resources.count
  end

  # === Scoping Tests ===

  test "default scope only filters by tenant not superagent" do
    # SubagentTaskRunResource only scopes by tenant, not by superagent
    # This allows a single task run to track resources across multiple studios
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )

    # The resource should be findable regardless of superagent
    found = SubagentTaskRunResource.find_by(id: resource.id)
    assert_not_nil found, "Resource should be findable"
    assert_equal @superagent.id, found.resource_superagent_id
  end

  # === resource_unscoped Tests ===

  test "resource_unscoped returns resource" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )

    fetched = resource.resource_unscoped
    assert_not_nil fetched
    assert_equal note.id, fetched.id
  end

  test "resource_unscoped returns nil for deleted resource" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )

    # Delete the note
    note.destroy!

    # resource_unscoped should return nil
    assert_nil resource.resource_unscoped
  end

  # === task_run_for Tests ===

  test "task_run_for returns task run that created the resource" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )

    found_task_run = SubagentTaskRunResource.task_run_for(note)
    assert_not_nil found_task_run
    assert_equal @task_run.id, found_task_run.id
  end

  test "task_run_for returns nil for resource not created by task run" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    # No SubagentTaskRunResource record created
    found_task_run = SubagentTaskRunResource.task_run_for(note)
    assert_nil found_task_run
  end

  test "task_run_for only matches create action type" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Create a record with update action type (not create)
    SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "update",
    )

    # Should not find it since it's not a "create" action
    found_task_run = SubagentTaskRunResource.task_run_for(note)
    assert_nil found_task_run
  end

  # === display_title Tests ===

  test "display_title for Note returns truncated title" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "My Important Note Title")
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )

    assert_equal "My Important Note Title", resource.display_title(note)
  end

  test "display_title for Decision returns truncated question" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user, question: "What should we do about this?")
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: decision,
      resource_superagent: @superagent,
      action_type: "create",
    )

    assert_equal "What should we do about this?", resource.display_title(decision)
  end

  test "display_title for Option includes prefix" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option A")
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: option,
      resource_superagent: @superagent,
      action_type: "add_options",
    )

    assert_equal "Option: Option A", resource.display_title(option)
  end

  test "display_title for Vote references option title" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Best Option")
    decision_participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant,
      superagent: @superagent,
      option: option,
      decision: decision,
      decision_participant: decision_participant,
      accepted: 1,
      preferred: 0,
    )
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: vote,
      resource_superagent: @superagent,
      action_type: "vote",
    )

    assert_equal "Vote on: Best Option", resource.display_title(vote)
  end

  test "display_title for NoteHistoryEvent references note title" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Important Announcement")
    history_event = NoteHistoryEvent.create!(
      tenant: @tenant,
      superagent: @superagent,
      note: note,
      user: @user,
      event_type: "read_confirmation",
      happened_at: Time.current,
    )
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: history_event,
      resource_superagent: @superagent,
      action_type: "confirm",
    )

    assert_equal "Confirmed: Important Announcement", resource.display_title(history_event)
  end

  test "display_title returns unknown for nil resource" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )

    assert_equal "Unknown resource", resource.display_title(nil)
  end

  test "display_title handles cross-superagent vote correctly" do
    # Create vote in different superagent
    other_superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "vote-studio-#{SecureRandom.hex(4)}")
    other_superagent.add_user!(@user)

    decision = Decision.create!(
      tenant: @tenant,
      superagent: other_superagent,
      created_by: @user,
      question: "Cross-studio decision?",
      description: "Test",
      deadline: 1.week.from_now,
      options_open: true,
    )
    decision_participant = DecisionParticipant.create!(
      tenant: @tenant,
      superagent: other_superagent,
      decision: decision,
      user: @user,
    )
    option = Option.create!(
      tenant: @tenant,
      superagent: other_superagent,
      decision: decision,
      decision_participant: decision_participant,
      title: "Cross-Studio Option",
    )
    vote = Vote.create!(
      tenant: @tenant,
      superagent: other_superagent,
      option: option,
      decision: decision,
      decision_participant: decision_participant,
      accepted: 1,
      preferred: 0,
    )

    resource = SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: vote,
      resource_superagent: other_superagent,
      action_type: "vote",
    )

    # display_title should work because it uses unscoped queries to fetch related resources
    assert_equal "Vote on: Cross-Studio Option", resource.display_title(vote)
  end

  # === set_tenant_id Tests ===

  test "tenant_id is auto-set from task_run if not provided" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    resource = SubagentTaskRunResource.new(
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )
    resource.valid?
    assert_equal @tenant.id, resource.tenant_id
  end

  # === Uniqueness Constraint Tests ===

  test "cannot create duplicate resource associations for same task run" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    SubagentTaskRunResource.create!(
      tenant: @tenant,
      subagent_task_run: @task_run,
      resource: note,
      resource_superagent: @superagent,
      action_type: "create",
    )

    # Attempting to create another association for the same resource should fail
    assert_raises ActiveRecord::RecordNotUnique do
      SubagentTaskRunResource.create!(
        tenant: @tenant,
        subagent_task_run: @task_run,
        resource: note,
        resource_superagent: @superagent,
        action_type: "update",
      )
    end
  end
end
