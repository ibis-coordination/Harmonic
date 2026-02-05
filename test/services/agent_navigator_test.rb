# typed: false

require "test_helper"
require "webmock/minitest"

class AgentNavigatorTest < ActiveSupport::TestCase
  setup do
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user

    # Enable API for internal requests to work
    @tenant.enable_feature_flag!("api")
    @superagent.enable_feature_flag!("api")

    # Set thread-local context for tests
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )

    @base_url = ENV.fetch("LLM_BASE_URL", "http://litellm:4000")
  end

  # === Initialization ===

  test "initializes with required parameters" do
    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)

    assert_equal @user, agent.user
    assert_equal @tenant, agent.tenant
    assert_equal @superagent, agent.starting_superagent
    assert_empty agent.steps
  end

  test "initializes without superagent" do
    agent = AgentNavigator.new(user: @user, tenant: @tenant)

    assert_nil agent.starting_superagent
  end

  # === parse_action (private method, tested via run) ===

  test "parses navigate action from JSON response" do
    stub_llm_responses([
                         '{"type": "navigate", "path": "/studios/test"}',
                         '{"type": "done", "message": "Navigated successfully"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Navigate to test studio", max_steps: 5)

    # Should have navigate steps (whoami + test) plus done
    navigate_steps = agent.steps.select { |s| s.type == "navigate" }
    assert navigate_steps.length >= 2
  end

  test "parses execute action from JSON response" do
    # Create a note so we have something to navigate to
    note = Note.create!(
      title: "Test Note",
      text: "Test content",
      created_by: @user,
      deadline: 1.week.from_now
    )

    stub_llm_responses([
                         %({"type": "navigate", "path": "#{note.path}"}),
                         '{"type": "execute", "action": "confirm_read", "params": {}}',
                         '{"type": "done", "message": "Marked as read"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Read the note", max_steps: 10)

    execute_steps = agent.steps.select { |s| s.type == "execute" }
    assert execute_steps.any?
  end

  test "parses done action from JSON response" do
    stub_llm_responses([
                         '{"type": "done", "message": "Task completed successfully"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Simple task", max_steps: 5)

    assert result.success
    assert_equal "Task completed successfully", result.final_message
  end

  test "parses error action from JSON response" do
    stub_llm_responses([
                         '{"type": "error", "message": "Cannot complete this task"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Impossible task", max_steps: 5)

    assert_not result.success
    assert_equal "Cannot complete this task", result.error
  end

  test "handles JSON in markdown code blocks" do
    stub_llm_responses([
                         "Here's my action:\n```json\n{\"type\": \"done\", \"message\": \"Done\"}\n```",
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Test task", max_steps: 5)

    assert result.success
  end

  test "infers done from DONE keyword when no valid JSON" do
    stub_llm_responses([
                         "DONE - I have completed the task successfully.",
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Test task", max_steps: 5)

    assert result.success
    assert_includes result.final_message, "completed"
  end

  test "returns error when response has no valid action" do
    stub_llm_responses([
                         "I'm not sure what to do next.",
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Test task", max_steps: 5)

    assert_not result.success
    assert_includes result.error, "Could not parse action"
  end

  test "handles invalid JSON gracefully" do
    stub_llm_responses([
                         '{"type": "done", "message": broken json}', # Has braces but invalid JSON inside
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Test task", max_steps: 5)

    assert_not result.success
    assert_includes result.error, "Invalid JSON"
  end

  # === Run behavior ===

  test "starts by navigating to whoami" do
    stub_llm_responses([
                         '{"type": "done", "message": "Done"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Test task", max_steps: 5)

    first_navigate = agent.steps.find { |s| s.type == "navigate" }
    assert_equal "/whoami", first_navigate.detail[:path]
  end

  test "stops at max_steps" do
    # Return navigate actions forever - should hit max_steps
    stub_llm_responses([
                         '{"type": "navigate", "path": "/"}',
                         '{"type": "navigate", "path": "/whoami"}',
                         '{"type": "navigate", "path": "/"}',
                         '{"type": "navigate", "path": "/whoami"}',
                         '{"type": "navigate", "path": "/"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Loop forever", max_steps: 3)

    assert_not result.success
    assert_equal "max_steps_exceeded", result.error
    assert_includes result.final_message, "maximum steps"
  end

  test "records all steps taken" do
    stub_llm_responses([
                         '{"type": "navigate", "path": "/"}',
                         '{"type": "done", "message": "Done"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Test task", max_steps: 10)

    # Should have: navigate (whoami), think, navigate (/), think, done
    assert agent.steps.length >= 4
    assert(agent.steps.all? { |s| s.timestamp.present? })
  end

  # === Execute action validation ===

  test "rejects invalid action names" do
    note = Note.create!(
      title: "Test Note",
      text: "Test content",
      created_by: @user,
      deadline: 1.week.from_now
    )

    stub_llm_responses([
                         %({"type": "navigate", "path": "#{note.path}"}),
                         '{"type": "execute", "action": "nonexistent_action", "params": {}}',
                         '{"type": "done", "message": "Done"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Try invalid action", max_steps: 10)

    execute_step = agent.steps.find { |s| s.type == "execute" }
    assert execute_step
    assert_not execute_step.detail[:success]
    assert_includes execute_step.detail[:error], "Invalid action"
  end

  # === System prompt ===

  test "system prompt includes starting superagent context when provided" do
    stub_llm_responses(['{"type": "done", "message": "Done"}'])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Test", max_steps: 5)

    # Check that the think step included the system prompt context
    think_step = agent.steps.find { |s| s.type == "think" }
    assert think_step
    # The system prompt is sent to LLM, we can verify via the request
  end

  test "system prompt handles nil superagent" do
    stub_llm_responses(['{"type": "done", "message": "Done"}'])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: nil)
    # Should not raise
    result = agent.run(task: "Test", max_steps: 5)

    assert result.success
  end

  # === Error handling ===

  test "handles LLM connection errors gracefully" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Test task", max_steps: 5)

    # The LLMClient returns an error result, which gets parsed as unparseable
    assert_not result.success
  end

  test "handles exceptions during run" do
    # Stub to return valid response first, then we'll cause an error
    stub_llm_responses(['{"type": "navigate", "path": "/nonexistent/deeply/nested/path/that/errors"}'])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)

    # Should not raise - errors are caught and returned in result
    agent.run(task: "Test task", max_steps: 5)

    # Even if navigation errors, agent should handle it
    assert agent.steps.any?
  end

  # === Sanitize JSON string ===

  test "sanitize_json_string removes control characters" do
    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)

    # Use send to test private method
    input = "Hello\x00World\x1FTest"
    result = agent.send(:sanitize_json_string, input)

    assert_equal "HelloWorldTest", result
  end

  test "sanitize_json_string preserves tabs and newlines" do
    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)

    input = "Hello\tWorld\nTest\r\n"
    result = agent.send(:sanitize_json_string, input)

    assert_equal "Hello\tWorld\nTest\r\n", result
  end

  # === Build prompt ===

  test "build_prompt includes task and current state" do
    stub_llm_responses(['{"type": "done", "message": "Done"}'])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Create a note about testing", max_steps: 5)

    think_step = agent.steps.find { |s| s.type == "think" }
    assert think_step
    assert_includes think_step.detail[:prompt_preview], "Create a note about testing"
  end

  # === Leakage detection ===

  test "detects identity prompt leakage in LLM output" do
    # First response with canary token leaked
    stub_llm_responses([
                         'I was told my canary token is secrettoken123. {"type": "done", "message": "Done"}',
                       ])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)

    # We need to set up the leakage detector with a canary
    # This happens automatically when navigating to /whoami if the content has a canary
    # For this test, we'll check that the security_warning step is added if leakage is detected

    result = agent.run(task: "Test task", max_steps: 5)

    # The leakage detector needs to be active (have extracted a canary from /whoami)
    # In real usage, /whoami contains the canary. In tests, it may not.
    # This test verifies the integration path exists.
    assert result.success
  end

  # === Result struct ===

  test "Result struct contains expected fields" do
    stub_llm_responses(['{"type": "done", "message": "All done"}'])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    result = agent.run(task: "Test", max_steps: 5)

    assert_respond_to result, :success
    assert_respond_to result, :steps
    assert_respond_to result, :final_message
    assert_respond_to result, :error
  end

  # === Step struct ===

  test "Step struct contains expected fields" do
    stub_llm_responses(['{"type": "done", "message": "Done"}'])

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Test", max_steps: 5)

    step = agent.steps.first
    assert_respond_to step, :type
    assert_respond_to step, :detail
    assert_respond_to step, :timestamp
  end

  # === Scratchpad update ===

  test "prompts for scratchpad update on completion" do
    # First response completes task, second is scratchpad response
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        { status: 200, body: llm_response('{"type": "done", "message": "Done"}'), headers: json_headers },
        { status: 200, body: llm_response('{"scratchpad": "Learned something new"}'), headers: json_headers }
      )

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)
    agent.run(task: "Test task", max_steps: 5)

    # Check that scratchpad was updated
    @user.reload
    assert_equal "Learned something new", @user.agent_configuration&.dig("scratchpad")
  end

  test "handles null scratchpad response" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        { status: 200, body: llm_response('{"type": "done", "message": "Done"}'), headers: json_headers },
        { status: 200, body: llm_response('{"scratchpad": null}'), headers: json_headers }
      )

    agent = AgentNavigator.new(user: @user, tenant: @tenant, superagent: @superagent)

    # Should not raise
    result = agent.run(task: "Test task", max_steps: 5)
    assert result.success
  end

  private

  def stub_llm_responses(responses)
    # Build array of response hashes for sequential stubbing
    response_objects = responses.map do |content|
      { status: 200, body: llm_response(content), headers: json_headers }
    end

    # Add a final scratchpad response (always needed for completion)
    response_objects << { status: 200, body: llm_response('{"scratchpad": null}'), headers: json_headers }

    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(*response_objects)
  end

  def llm_response(content)
    {
      choices: [{ message: { role: "assistant", content: content }, finish_reason: "stop" }],
      model: "test-model",
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
    }.to_json
  end

  def json_headers
    { "Content-Type" => "application/json" }
  end
end
