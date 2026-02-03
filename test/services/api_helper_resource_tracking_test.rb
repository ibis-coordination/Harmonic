require "test_helper"

class ApiHelperResourceTrackingTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle,
    )

    @subagent = create_subagent(parent: @user, name: "Tracking Subagent")
    @tenant.add_user!(@subagent)
    @superagent.add_user!(@subagent)

    @task_run = SubagentTaskRun.create!(
      tenant: @tenant,
      subagent: @subagent,
      initiated_by: @user,
      task: "Test task for tracking",
      max_steps: 10,
      status: "running",
    )
  end

  def teardown
    SubagentTaskRun.clear_thread_scope
  end

  # === Context Management Tests ===

  test "resource tracking only happens when task run context is set" do
    # Without context, no tracking
    assert_nil SubagentTaskRun.current_id

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: { text: "No tracking note" },
      request: {},
    )
    note = api_helper.create_note

    assert_equal 0, SubagentTaskRunResource.count, "Should not track without task run context"
  end

  test "resource tracking happens when task run context is set" do
    SubagentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: { text: "Tracked note" },
      request: {},
    )
    note = api_helper.create_note

    assert_equal 1, SubagentTaskRunResource.count
    resource = SubagentTaskRunResource.first
    assert_equal @task_run.id, resource.subagent_task_run_id
    assert_equal "Note", resource.resource_type
    assert_equal note.id, resource.resource_id
    assert_equal "create", resource.action_type
  end

  # === Note Tracking Tests ===

  test "create_note tracks resource with correct action_type and display_path" do
    SubagentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: { text: "Test note body" },
      request: {},
    )
    note = api_helper.create_note

    resource = SubagentTaskRunResource.find_by(resource_id: note.id)
    assert_not_nil resource
    assert_equal "create", resource.action_type
    assert_equal @superagent.id, resource.resource_superagent_id
    assert_equal note.path, resource.display_path
  end

  # === Decision Tracking Tests ===

  test "create_decision tracks resource" do
    SubagentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: {
        question: "Should we proceed?",
        description: "A test decision",
        deadline: 1.week.from_now,
      },
      request: {},
    )
    decision = api_helper.create_decision

    resource = SubagentTaskRunResource.find_by(resource_id: decision.id)
    assert_not_nil resource
    assert_equal "Decision", resource.resource_type
    assert_equal "create", resource.action_type
    assert_equal decision.path, resource.display_path
  end

  # === Option Tracking Tests ===

  test "create_decision_option tracks resource" do
    SubagentTaskRun.current_id = @task_run.id

    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      current_decision: decision,
      params: { title: "Option A" },
      request: {},
    )
    option = api_helper.create_decision_option

    resource = SubagentTaskRunResource.find_by(resource_id: option.id)
    assert_not_nil resource
    assert_equal "Option", resource.resource_type
    assert_equal "add_option", resource.action_type
    assert_equal decision.path, resource.display_path
  end

  # === Vote Tracking Tests ===

  test "vote tracks resource" do
    SubagentTaskRun.current_id = @task_run.id

    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      current_decision: decision,
      params: { option_title: option.title, accept: true, prefer: false },
      request: {},
    )
    vote = api_helper.vote

    resource = SubagentTaskRunResource.find_by(resource_id: vote.id)
    assert_not_nil resource
    assert_equal "Vote", resource.resource_type
    assert_equal "vote", resource.action_type
    assert_equal decision.path, resource.display_path
  end

  # === Confirm Read Tracking Tests ===

  test "confirm_read tracks NoteHistoryEvent resource" do
    SubagentTaskRun.current_id = @task_run.id

    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      current_resource_model: Note,
      current_resource: note,
      params: {},
      request: {},
    )
    history_event = api_helper.confirm_read

    resource = SubagentTaskRunResource.find_by(resource_id: history_event.id)
    assert_not_nil resource
    assert_equal "NoteHistoryEvent", resource.resource_type
    assert_equal "confirm", resource.action_type
    assert_equal note.path, resource.display_path
  end

  # === Task Run Query Methods Tests ===

  test "task_run.created_notes returns notes created during run" do
    SubagentTaskRun.current_id = @task_run.id

    api_helper1 = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: { text: "First note" },
      request: {},
    )
    note1 = api_helper1.create_note

    api_helper2 = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: { text: "Second note" },
      request: {},
    )
    note2 = api_helper2.create_note

    created_notes = @task_run.created_notes
    assert_equal 2, created_notes.count
    assert_includes created_notes.pluck(:id), note1.id
    assert_includes created_notes.pluck(:id), note2.id
  end

  test "task_run.created_decisions returns decisions created during run" do
    SubagentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: {
        question: "Test decision?",
        description: "Test description",
        deadline: 1.week.from_now,
      },
      request: {},
    )
    decision = api_helper.create_decision

    created_decisions = @task_run.created_decisions
    assert_equal 1, created_decisions.count
    assert_equal decision.id, created_decisions.first.id
  end

  test "task_run.all_resources returns all tracked resources" do
    SubagentTaskRun.current_id = @task_run.id

    api_helper1 = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: { text: "A note" },
      request: {},
    )
    note = api_helper1.create_note

    api_helper2 = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: {
        question: "A decision?",
        description: "Test description",
        deadline: 1.week.from_now,
      },
      request: {},
    )
    decision = api_helper2.create_decision

    all_resources = @task_run.all_resources
    assert_equal 2, all_resources.count
    resource_classes = all_resources.map(&:class).map(&:name)
    assert_includes resource_classes, "Note"
    assert_includes resource_classes, "Decision"
  end

  # === Error Handling Tests ===

  test "tracking failure does not prevent resource creation" do
    SubagentTaskRun.current_id = @task_run.id

    # Delete the task run to simulate a tracking failure
    @task_run.destroy!

    api_helper = ApiHelper.new(
      current_user: @subagent,
      current_tenant: @tenant,
      current_superagent: @superagent,
      params: { text: "Note despite tracking failure" },
      request: {},
    )

    # Should not raise, note should still be created
    note = api_helper.create_note
    assert note.persisted?
    assert_equal 0, SubagentTaskRunResource.count
  end
end
