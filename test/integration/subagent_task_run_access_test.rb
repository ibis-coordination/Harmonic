require "test_helper"

class SubagentTaskRunAccessTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @parent = @global_user
    @tenant.enable_feature_flag!("subagents")

    @subagent = create_subagent_for(@parent, "My Subagent")
    @other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(@other_parent)
    @superagent.add_user!(@other_parent)
    @other_subagent = create_subagent_for(@other_parent, "Other Subagent")
    @other_task_run = create_task_run(@other_subagent, @other_parent)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  private

  def create_subagent_for(parent, name)
    subagent = create_subagent(parent: parent, name: name)
    @tenant.add_user!(subagent)
    @superagent.add_user!(subagent)
    subagent
  end

  def create_task_run(subagent, initiated_by, task: "Test task")
    SubagentTaskRun.create!(
      tenant: @tenant,
      subagent: subagent,
      initiated_by: initiated_by,
      task: task,
      max_steps: SubagentTaskRun::DEFAULT_MAX_STEPS,
      status: "completed",
      success: true,
      final_message: "Completed",
      started_at: 1.minute.ago,
      completed_at: Time.current
    )
  end

  # ====================
  # Task Run Show Page Access
  # ====================

  test "parent can access their own subagent's task run page" do
    task_run = create_task_run(@subagent, @parent)
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@subagent.handle}/runs/#{task_run.id}"

    assert_response :success
  end

  test "parent cannot access another user's subagent's task run page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@other_subagent.handle}/runs/#{@other_task_run.id}"

    assert_response :not_found
  end

  test "parent cannot access task run page with correct subagent handle but wrong run" do
    # Try to access other_task_run but using own subagent's handle
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@subagent.handle}/runs/#{@other_task_run.id}"

    assert_response :not_found
  end

  # ====================
  # Task Runs List Page Access
  # ====================

  test "parent can access their own subagent's runs list" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@subagent.handle}/runs"

    assert_response :success
  end

  test "parent cannot access another user's subagent's runs list" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@other_subagent.handle}/runs"

    assert_response :not_found
  end

  # ====================
  # Run Task Page Access
  # ====================

  test "parent can access their own subagent's run task page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@subagent.handle}/run"

    assert_response :success
  end

  test "parent cannot access another user's subagent's run task page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@other_subagent.handle}/run"

    assert_response :not_found
  end

  # ====================
  # Subagents Index Page
  # ====================

  test "parent can access subagents index page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents"

    assert_response :success
    # Should only see their own subagent, not other parent's subagent
    assert_match @subagent.name, response.body
    assert_no_match(/#{@other_subagent.name}/, response.body)
  end

  test "subagent cannot access subagents index page" do
    # Create API token for subagent
    token = ApiToken.create!(
      user: @subagent,
      tenant: @tenant,
      name: "Test Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now
    )

    get "/subagents", headers: { "Authorization" => "Bearer #{token.plaintext_token}" }

    assert_response :forbidden
  end

  # ====================
  # Edge Cases
  # ====================

  test "unauthenticated user cannot access task run pages" do
    get "/subagents/#{@subagent.handle}/runs/#{@other_task_run.id}"

    assert_response :redirect
  end

  test "accessing non-existent subagent returns not found" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/nonexistent-handle/runs"

    assert_response :not_found
  end

  test "accessing non-existent task run returns not found" do
    sign_in_as(@parent, tenant: @tenant)

    get "/subagents/#{@subagent.handle}/runs/nonexistent-id"

    assert_response :not_found
  end
end
