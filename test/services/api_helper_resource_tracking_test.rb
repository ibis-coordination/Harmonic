require "test_helper"

class ApiHelperResourceTrackingTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle,
    )

    @ai_agent = create_ai_agent(parent: @user, name: "Tracking AiAgent")
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)

    @task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task for tracking",
      max_steps: 10,
      status: "running",
    )
  end

  def teardown
    AiAgentTaskRun.clear_thread_scope
  end

  # === Context Management Tests ===

  test "resource tracking only happens when task run context is set" do
    # Without context, no tracking
    assert_nil AiAgentTaskRun.current_id

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      params: { text: "No tracking note" },
      request: {},
    )
    note = api_helper.create_note

    assert_equal 0, AiAgentTaskRunResource.count, "Should not track without task run context"
  end

  test "resource tracking happens when task run context is set" do
    AiAgentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      params: { text: "Tracked note" },
      request: {},
    )
    note = api_helper.create_note

    assert_equal 1, AiAgentTaskRunResource.count
    resource = AiAgentTaskRunResource.first
    assert_equal @task_run.id, resource.ai_agent_task_run_id
    assert_equal "Note", resource.resource_type
    assert_equal note.id, resource.resource_id
    assert_equal "create", resource.action_type
  end

  # === Note Tracking Tests ===

  test "create_note tracks resource with correct action_type and display_path" do
    AiAgentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      params: { text: "Test note body" },
      request: {},
    )
    note = api_helper.create_note

    resource = AiAgentTaskRunResource.find_by(resource_id: note.id)
    assert_not_nil resource
    assert_equal "create", resource.action_type
    assert_equal @collective.id, resource.resource_collective_id
    assert_equal note.path, resource.display_path
  end

  # === Decision Tracking Tests ===

  test "create_decision tracks resource" do
    AiAgentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      params: {
        question: "Should we proceed?",
        description: "A test decision",
        deadline: 1.week.from_now,
      },
      request: {},
    )
    decision = api_helper.create_decision

    resource = AiAgentTaskRunResource.find_by(resource_id: decision.id)
    assert_not_nil resource
    assert_equal "Decision", resource.resource_type
    assert_equal "create", resource.action_type
    assert_equal decision.path, resource.display_path
  end

  # === Option Tracking Tests ===

  test "create_decision_options tracks multiple resources" do
    AiAgentTaskRun.current_id = @task_run.id

    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      current_decision: decision,
      params: { titles: ["Option A", "Option B", "Option C"] },
      request: {},
    )
    options = api_helper.create_decision_options

    assert_equal 3, options.count
    assert_equal ["Option A", "Option B", "Option C"], options.map(&:title)

    # Each option should be tracked
    options.each do |option|
      resource = AiAgentTaskRunResource.find_by(resource_id: option.id)
      assert_not_nil resource
      assert_equal "Option", resource.resource_type
      assert_equal "add_options", resource.action_type
      assert_equal decision.path, resource.display_path
    end
  end

  # === Vote Tracking Tests ===

  test "create_votes tracks multiple vote resources" do
    AiAgentTaskRun.current_id = @task_run.id

    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    option1 = create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision, title: "Option A")
    option2 = create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision, title: "Option B")

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      current_decision: decision,
      params: {
        votes: [
          { option_title: option1.title, accept: true, prefer: false },
          { option_title: option2.title, accept: true, prefer: true },
        ]
      },
      request: {},
    )
    votes = api_helper.create_votes

    assert_equal 2, votes.count
    votes.each do |vote|
      resource = AiAgentTaskRunResource.find_by(resource_id: vote.id)
      assert_not_nil resource
      assert_equal "Vote", resource.resource_type
      assert_equal "vote", resource.action_type
      assert_equal decision.path, resource.display_path
    end
  end

  # === Confirm Read Tracking Tests ===

  test "confirm_read tracks NoteHistoryEvent resource" do
    AiAgentTaskRun.current_id = @task_run.id

    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      current_resource_model: Note,
      current_resource: note,
      params: {},
      request: {},
    )
    history_event = api_helper.confirm_read

    resource = AiAgentTaskRunResource.find_by(resource_id: history_event.id)
    assert_not_nil resource
    assert_equal "NoteHistoryEvent", resource.resource_type
    assert_equal "confirm", resource.action_type
    assert_equal note.path, resource.display_path
  end

  # === Task Run Query Methods Tests ===

  test "task_run.created_notes returns notes created during run" do
    AiAgentTaskRun.current_id = @task_run.id

    api_helper1 = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      params: { text: "First note" },
      request: {},
    )
    note1 = api_helper1.create_note

    api_helper2 = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
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
    AiAgentTaskRun.current_id = @task_run.id

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
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
    AiAgentTaskRun.current_id = @task_run.id

    api_helper1 = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      params: { text: "A note" },
      request: {},
    )
    note = api_helper1.create_note

    api_helper2 = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
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
    AiAgentTaskRun.current_id = @task_run.id

    # Delete the task run to simulate a tracking failure
    @task_run.destroy!

    api_helper = ApiHelper.new(
      current_user: @ai_agent,
      current_tenant: @tenant,
      current_collective: @collective,
      params: { text: "Note despite tracking failure" },
      request: {},
    )

    # Should not raise, note should still be created
    note = api_helper.create_note
    assert note.persisted?
    assert_equal 0, AiAgentTaskRunResource.count
  end
end
