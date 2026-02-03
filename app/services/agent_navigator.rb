# typed: strict
# frozen_string_literal: true

# An AI agent that can navigate and act in Harmonic using the markdown UI.
#
# This combines LLMClient (reasoning) with MarkdownUiService (navigation/actions)
# to create an autonomous agent that can complete tasks in the app.
#
# @example Run an agent to create a note
#   agent = AgentNavigator.new(user: subagent, tenant: tenant, superagent: studio)
#   result = agent.run(task: "Create a note saying hello to the team")
#   result[:steps].each { |step| puts step[:type] }
#
class AgentNavigator
  extend T::Sig

  # Represents a single step taken by the agent
  class Step < T::Struct
    const :type, String # "navigate", "execute", "think", "done", "error"
    const :detail, T::Hash[Symbol, T.untyped]
    const :timestamp, T.any(Time, ActiveSupport::TimeWithZone)
  end

  # Result of running the agent
  class Result < T::Struct
    const :success, T::Boolean
    const :steps, T::Array[Step]
    const :final_message, String
    const :error, T.nilable(String)
  end

  sig { returns(User) }
  attr_reader :user

  sig { returns(Tenant) }
  attr_reader :tenant

  sig { returns(T.nilable(Superagent)) }
  attr_reader :starting_superagent

  sig { returns(T::Array[Step]) }
  attr_reader :steps

  sig do
    params(
      user: User,
      tenant: Tenant,
      superagent: T.nilable(Superagent),
      model: T.nilable(String)
    ).void
  end
  def initialize(user:, tenant:, superagent: nil, model: nil)
    @user = user
    @tenant = tenant
    @starting_superagent = superagent
    @llm = T.let(LLMClient.new(model: model || "default"), LLMClient)
    # Initialize service without a fixed superagent - it will resolve dynamically from paths
    @service = T.let(
      MarkdownUiService.new(tenant: tenant, superagent: superagent, user: user),
      MarkdownUiService
    )
    @steps = T.let([], T::Array[Step])
    @current_path = T.let(nil, T.nilable(String))
    @current_content = T.let(nil, T.nilable(String))
    @current_actions = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
    @last_action_result = T.let(nil, T.nilable(String))
    @messages = T.let([], T::Array[T::Hash[Symbol, String]])
  end

  # Run the agent to complete a task.
  #
  # @param task [String] Description of what the agent should do
  # @param max_steps [Integer] Maximum number of actions before stopping
  # @return [Result] The result including all steps taken
  sig { params(task: String, max_steps: Integer).returns(Result) }
  def run(task:, max_steps: 15)
    @steps = []
    @messages = []

    # Start by navigating to the whoami page to understand the context
    navigate_to("/whoami")

    loop do
      # Stop if we've reached the step limit
      break if @steps.count >= max_steps

      # Ask the LLM what to do next
      response = think(task, @steps.count)

      # Parse the action from the response
      action = parse_action(response)

      case action[:type]
      when "navigate"
        navigate_to(action[:path])
      when "execute"
        execute_action(action[:action], action[:params] || {})
      when "done"
        add_step("done", { message: action[:message] })
        return Result.new(
          success: true,
          steps: @steps,
          final_message: action[:message] || "Task completed",
          error: nil
        )
      when "error"
        add_step("error", { message: action[:message] })
        return Result.new(
          success: false,
          steps: @steps,
          final_message: action[:message] || "Agent encountered an error",
          error: action[:message]
        )
      end
    end

    # Hit max steps
    Result.new(
      success: false,
      steps: @steps,
      final_message: "Reached maximum steps (#{max_steps}) without completing task",
      error: "max_steps_exceeded"
    )
  rescue StandardError => e
    add_step("error", { message: e.message, backtrace: e.backtrace&.first(5) })
    Result.new(
      success: false,
      steps: @steps,
      final_message: "Agent encountered an error: #{e.message}",
      error: e.message
    )
  end

  private

  sig { params(path: String).void }
  def navigate_to(path)
    result = @service.navigate(path)
    @current_path = result[:path]
    @current_content = result[:content]
    @current_actions = result[:actions] || []
    @last_action_result = nil # Clear previous action result when navigating

    add_step("navigate", {
               path: path,
               resolved_path: result[:path],
               content_preview: result[:content],
               available_actions: @current_actions.map { |a| a[:name] },
               error: result[:error],
             })
  end

  sig { params(action_name: String, params: T::Hash[Symbol, T.untyped]).void }
  def execute_action(action_name, params)
    result = @service.execute_action(action_name, params)

    add_step("execute", {
               action: action_name,
               params: params,
               success: result[:success],
               content_preview: result[:content],
               error: result[:error],
             })

    # Save the result so the LLM knows what happened
    @last_action_result = if result[:success]
                            "SUCCESS: #{action_name} completed. #{result[:content]&.first(200)}"
                          else
                            "FAILED: #{action_name} failed. #{result[:error]}"
                          end

    # Update current state if action succeeded and returned a path
    return unless result[:success] && result[:path]

    @current_path = result[:path]
    @current_content = result[:content]
  end

  sig { params(task: String, step_number: Integer).returns(String) }
  def think(task, step_number)
    # Add the current state as a user message
    @messages << { role: "user", content: build_prompt(task, step_number) }

    # Send full conversation history to the LLM
    result = @llm.chat(messages: @messages, system_prompt: system_prompt)

    # Add the assistant's response to history
    @messages << { role: "assistant", content: result.content }

    add_step("think", {
               step_number: step_number,
               response_preview: result.content,
             })

    result.content
  end

  sig { params(response: String).returns(T::Hash[Symbol, T.untyped]) }
  def parse_action(response)
    # Try to extract JSON from the response
    json_match = response.match(/```json\s*(.*?)\s*```/m) || response.match(/\{.*\}/m)

    if json_match
      json_str = json_match[1] || json_match[0]
      parsed = JSON.parse(json_str.to_s, symbolize_names: true)
      return parsed if parsed.is_a?(Hash) && parsed[:type]
    end

    # If no valid JSON, try to infer from text
    if response.include?("DONE") || response.downcase.include?("task complete")
      { type: "done", message: "Task completed based on LLM response" }
    else
      { type: "error", message: "Could not parse action from LLM response" }
    end
  rescue JSON::ParserError
    { type: "error", message: "Invalid JSON in LLM response" }
  end

  sig { params(type: String, detail: T::Hash[Symbol, T.untyped]).void }
  def add_step(type, detail)
    @steps << Step.new(type: type, detail: detail, timestamp: Time.current)
  end

  sig { params(task: String, step_number: Integer).returns(String) }
  def build_prompt(task, step_number)
    actions_list = @current_actions.map do |action|
      params_desc = (action[:params] || []).map { |p| "#{p[:name]} (#{p[:required] ? "required" : "optional"})" }.join(", ")
      "- #{action[:name]}: #{action[:description] || "No description"}" + (params_desc.present? ? " [params: #{params_desc}]" : "")
    end.join("\n")

    last_action_info = if @last_action_result
                         "\n### Previous Action Result:\n#{@last_action_result}\n"
                       else
                         ""
                       end

    <<~PROMPT
      ## Current State

      **Step**: #{step_number + 1}
      **Current Path**: #{@current_path || "Not navigated yet"}
      #{last_action_info}
      ### Current Page Content:
      ```markdown
      #{@current_content&.first(4000) || "No content yet"}
      ```

      ### Available Actions:
      #{actions_list.presence || "No actions available at this path"}

      ## Your Task
      #{task}

      ## Instructions
      Based on the current page and your task, decide what to do next.

      **IMPORTANT**: If your previous action succeeded and your task is complete, respond with "done".
      Do not repeat the same action multiple times.

      Respond with a JSON object:

      To navigate to a different page:
      ```json
      {"type": "navigate", "path": "/path/to/page"}
      ```

      To execute an action:
      ```json
      {"type": "execute", "action": "action_name", "params": {"param1": "value1"}}
      ```

      When the task is complete:
      ```json
      {"type": "done", "message": "Description of what was accomplished"}
      ```

      If you cannot complete the task:
      ```json
      {"type": "error", "message": "Explanation of the problem"}
      ```

      Think step by step, then provide your action as JSON.
    PROMPT
  end

  sig { returns(String) }
  def system_prompt
    starting_context = if @starting_superagent
                         <<~CONTEXT
                           **Starting context**: You started in the "#{@starting_superagent.name}" studio (handle: #{@starting_superagent.handle}).
                           You can navigate to other studios if needed for your task.
                         CONTEXT
                       else
                         "**Starting context**: You have access to all studios the user is a member of."
                       end

    <<~PROMPT
      You are an AI agent navigating Harmonic, a group coordination application.
      You can view pages (markdown content) and execute actions to accomplish tasks.

      #{starting_context}

      Key concepts in Harmonic:
      - **Studios**: Workspaces where groups collaborate (paths like "/studios/{handle}")
      - **Notes**: Posts/content for sharing information (paths like "/studios/{handle}/note" to create, "/n/{id}" to view)
      - **Decisions**: Questions that participants vote on using acceptance voting (paths like "/studios/{handle}/decide" to create, "/d/{id}" to view)
      - **Commitments**: Action pledges that activate when critical mass is reached (paths like "/studios/{handle}/commit" to create, "/c/{id}" to view)
      - **Cycles**: Time-bounded activity windows (like sprints)

      Navigation tips:
      - The home page "/" shows available studios
      - Navigate to a studio: "/studios/{handle}"
      - Create content in a studio: "/studios/{handle}/note", "/studios/{handle}/decide", "/studios/{handle}/commit"
      - View individual items: "/n/{id}" for notes, "/d/{id}" for decisions, "/c/{id}" for commitments
      - Check your context: "/whoami" shows who you are and what you can access

      CRITICAL: After each action, check the "Previous Action Result" section.
      - If it says "SUCCESS", the action worked. Check if your task is now complete.
      - If your task is complete, respond with {"type": "done", "message": "..."}.
      - Do NOT repeat the same action if it already succeeded.

      Always respond with valid JSON specifying your next action.
      Be concise and focused on completing the task efficiently.
    PROMPT
  end
end
