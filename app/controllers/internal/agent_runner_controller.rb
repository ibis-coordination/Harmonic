# typed: true
# frozen_string_literal: true

# Internal API for agent-runner service.
# Inherits IP restriction, HMAC verification, and tenant resolution from BaseController.
module Internal
  class AgentRunnerController < BaseController
    extend T::Sig

    class TaskRunNotFound < StandardError; end
    rescue_from TaskRunNotFound, with: :render_task_run_not_found

    # POST /internal/agent-runner/tasks/:id/claim
    sig { void }
    def claim
      task_run = find_task_run!
      if task_run.status != "queued"
        render json: { error: "Task is not queued (status: #{task_run.status})" }, status: :conflict
        return
      end

      task_run.update!(status: "running", started_at: Time.current)
      broadcast_chat_status(task_run, "working")
      render json: { status: "ok" }
    end

    # POST /internal/agent-runner/tasks/:id/step
    sig { void }
    def step
      task_run = find_task_run!
      steps = params[:steps]

      unless steps.is_a?(Array)
        render json: { error: "steps must be an array" }, status: :unprocessable_entity
        return
      end

      # Determine the next position (0-based).
      # The unique index on (ai_agent_task_run_id, position) guards against
      # concurrent inserts producing duplicate positions.
      next_position = task_run.agent_session_steps.maximum(:position)&.+(1) || 0

      step_offset = 0
      steps.each do |s|
        step_type = s[:type]
        timestamp = s[:timestamp].present? ? Time.parse(s[:timestamp]) : Time.current

        # Message steps are stored as ChatMessage records, not AgentSessionSteps
        if step_type == "message"
          next unless task_run.chat_session_id.present?

          chat_session = T.must(task_run.chat_session)
          chat_message = ChatMessage.create!(
            tenant: task_run.tenant,
            collective: chat_session.collective,
            chat_session_id: task_run.chat_session_id,
            sender_id: s[:sender_id],
            content: s[:detail]&.dig("content").presence || "(empty)",
            created_at: timestamp,
          )
          track_chat_message_resource(task_run, chat_message)
          broadcast_chat_message(task_run, chat_message)
        else
          step_record = task_run.agent_session_steps.create!(
            position: next_position + step_offset,
            step_type: step_type,
            detail: s[:detail] || {},
            created_at: timestamp,
            sender_id: s[:sender_id],
          )
          step_offset += 1

          if step_type == "navigate" || step_type == "execute"
            broadcast_chat_activity(task_run, step_record)
          end
        end
      end

      task_run.update!(
        steps_count: task_run.agent_session_steps.count,
      )

      render json: { status: "ok" }
    end

    # POST /internal/agent-runner/tasks/:id/complete
    sig { void }
    def complete
      task_run = find_task_run!
      return unless guard_terminal_transition!(task_run)

      input_tokens = nonneg_int_param(:input_tokens)
      output_tokens = nonneg_int_param(:output_tokens)
      total_tokens = nonneg_int_param(:total_tokens)

      task_run.update!(
        status: params[:success] ? "completed" : "failed",
        success: params[:success] || false,
        final_message: params[:final_message],
        error: params[:error],
        steps_count: task_run.agent_session_steps.count,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens,
        completed_at: Time.current,
      )

      save_chat_navigation_state(task_run)
      if task_run.success
        broadcast_chat_status(task_run, "completed")
      else
        broadcast_chat_status(task_run, "error", error: task_run.error)
      end
      destroy_task_token(task_run)
      task_run.notify_parent_automation_runs!
      auto_dispatch_next_chat_turn(task_run)

      render json: { status: "ok" }
    end

    # GET /internal/agent-runner/chat/:chat_session_id/history
    #
    # Returns conversation history for the agent-runner to rebuild LLM context.
    # Includes messages AND action summaries so the agent knows what it did
    # between messages (which pages it visited, what actions it took).
    sig { void }
    def chat_history
      chat_session = ChatSession.find_by(id: params[:chat_session_id])
      unless chat_session
        render json: { error: "Chat session not found" }, status: :not_found
        return
      end

      task_run_ids = chat_session.task_runs.select(:id)
      max_context_messages = 50

      # Sliding window: find the cutoff timestamp from the Nth-most-recent chat
      # message, then load only data from that point forward.
      cutoff_timestamp = chat_session.chat_messages
        .order(created_at: :desc)
        .offset(max_context_messages)
        .limit(1)
        .pick(:created_at)

      # Load chat messages (from ChatMessage table)
      msg_scope = chat_session.chat_messages.includes(:sender).order(:created_at)
      msg_scope = msg_scope.where("created_at >= ?", cutoff_timestamp) if cutoff_timestamp
      chat_msgs = msg_scope.to_a

      # Load action steps (navigate/execute from AgentSessionStep) for interleaving
      action_scope = AgentSessionStep
        .where(ai_agent_task_run_id: task_run_ids, step_type: %w[navigate execute])
        .order(:created_at, :position)
      action_scope = action_scope.where("created_at >= ?", cutoff_timestamp) if cutoff_timestamp
      action_steps = action_scope.to_a

      # Merge messages and action steps chronologically
      messages = []
      action_buffer = []
      all_items = (chat_msgs.map { |m| [:message, m] } + action_steps.map { |s| [:action, s] })
        .sort_by { |_type, item| item.created_at }

      T.unsafe(all_items).each do |type, item|
        case type
        when :message
          # Flush accumulated action summary before the message
          if action_buffer.any?
            messages << {
              content: "[Actions taken: #{action_buffer.join(", ")}]",
              role: "system",
              timestamp: item.created_at.iso8601,
            }
            action_buffer = []
          end

          messages << {
            content: item.content,
            sender_id: item.sender_id,
            sender_name: item.sender&.name,
            role: item.sender_id == chat_session.ai_agent_id ? "assistant" : "user",
            timestamp: item.created_at.iso8601,
          }
        when :action
          case item.step_type
          when "navigate"
            path = item.detail&.dig("path")
            action_buffer << "navigated to #{path}" if path.present?
          when "execute"
            action_name = item.detail&.dig("action")
            success = item.detail&.dig("success")
            action_buffer << "#{action_name} (#{success ? "success" : "failed"})" if action_name.present?
          end
        end
      end

      # Flush any trailing action summary
      if action_buffer.any?
        messages << {
          content: "[Actions taken: #{action_buffer.join(", ")}]",
          role: "system",
          timestamp: all_items.last&.last&.created_at&.iso8601,
        }
      end

      render json: { messages: messages, current_state: chat_session.current_state }
    end

    # POST /internal/agent-runner/tasks/:id/fail
    #
    # Method is `fail_task`, not `fail`, to avoid shadowing `Kernel#fail`.
    sig { void }
    def fail_task
      task_run = find_task_run!
      return unless guard_terminal_transition!(task_run)

      task_run.update!(
        status: "failed",
        success: false,
        error: params[:error],
        completed_at: Time.current,
      )

      broadcast_chat_status(task_run, "error", error: params[:error])
      destroy_task_token(task_run)
      task_run.notify_parent_automation_runs!

      render json: { status: "ok" }
    end

    # PUT /internal/agent-runner/tasks/:id/scratchpad
    sig { void }
    def scratchpad
      task_run = find_task_run!
      content = params[:scratchpad]

      unless content.is_a?(String)
        render json: { error: "scratchpad must be a string" }, status: :unprocessable_entity
        return
      end

      sanitized = content.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "").truncate(10_000, omission: "")

      ai_agent = T.must(task_run.ai_agent)
      config = ai_agent.agent_configuration || {}
      config["scratchpad"] = sanitized
      ai_agent.update!(agent_configuration: config)

      render json: { status: "ok" }
    end

    # GET /internal/agent-runner/tasks/:id/status
    sig { void }
    def status
      task_run = find_task_run!
      render json: { status: task_run.status }
    end

    # POST /internal/agent-runner/tasks/:id/preflight
    sig { void }
    def preflight
      task_run = find_task_run!
      ai_agent = T.must(task_run.ai_agent)
      tenant = T.must(task_run.tenant)

      agent_tenant_user = ai_agent.tenant_users.find_by(tenant_id: tenant.id)
      if ai_agent.suspended?
        render json: { status: "fail", reason: "Agent is suspended" }
        return
      end
      if agent_tenant_user&.archived?
        render json: { status: "fail", reason: "Agent is deactivated" }
        return
      end
      if ai_agent.pending_billing_setup?
        render json: { status: "fail", reason: "Agent is pending billing setup" }
        return
      end

      if tenant.feature_enabled?("stripe_billing")
        billing_customer = ai_agent.billing_customer
        unless billing_customer&.active?
          render json: { status: "fail", reason: "Billing is not set up" }
          return
        end

        if ENV.fetch("LLM_GATEWAY_MODE", "litellm") == "stripe_gateway"
          credit_balance = StripeService.get_credit_balance(billing_customer)
          # Distinguish "Stripe API failed" (nil) from "truly empty" (0).
          # A Stripe outage should not look like "user is out of credit" — let
          # the run proceed and surface any real billing issue on the actual
          # LLM call rather than failing here with a misleading reason.
          if credit_balance.nil?
            Rails.logger.warn("[Internal::AgentRunner] Credit balance unavailable for customer #{billing_customer.stripe_id}; allowing preflight")
          elsif credit_balance <= 0
            render json: { status: "fail", reason: "Insufficient credit balance" }
            return
          end
        end
      end

      render json: { status: "ok" }
    end

    private

    sig { returns(AiAgentTaskRun) }
    def find_task_run!
      # Tenant scope is set by BaseController from the subdomain,
      # so this query is automatically scoped to the correct tenant.
      task_run = AiAgentTaskRun.find_by(id: params[:id])
      raise TaskRunNotFound unless task_run
      task_run
    end

    sig { params(_exception: StandardError).void }
    def render_task_run_not_found(_exception)
      render json: { error: "Task run not found" }, status: :not_found
    end

    sig { params(task_run: AiAgentTaskRun).void }
    def destroy_task_token(task_run)
      ApiToken.unscope(where: :internal)
        .where(context_type: "AiAgentTaskRun", context_id: task_run.id, internal: true)
        .find_each(&:destroy)
    end

    # Refuse to transition a task that's already in a terminal state
    # (completed / failed / cancelled). Prevents a late agent report from
    # overwriting a user-initiated cancel, or from duplicating a completion
    # on a webhook / dispatch retry.
    sig { params(task_run: AiAgentTaskRun).returns(T::Boolean) }
    def guard_terminal_transition!(task_run)
      return true if task_run.status == "running" || task_run.status == "queued"

      Rails.logger.info(
        "[Internal::AgentRunner] Refusing #{action_name} for task #{task_run.id} in terminal state #{task_run.status}",
      )
      render json: { error: "Task is in terminal state: #{task_run.status}" }, status: :conflict
      false
    end

    # Persist the agent's final navigation state so the next turn can resume there
    sig { params(task_run: AiAgentTaskRun).void }
    def save_chat_navigation_state(task_run)
      return unless task_run.mode == "chat_turn"

      chat_session = task_run.chat_session
      return unless chat_session

      current_state_param = params[:current_state]
      return unless current_state_param.is_a?(ActionController::Parameters) || current_state_param.is_a?(Hash)

      state = chat_session.current_state || {}
      state["current_path"] = current_state_param[:current_path] if current_state_param[:current_path].present?

      chat_session.update!(current_state: state)
    rescue StandardError => e
      Rails.logger.error("[Internal::AgentRunner] Failed to save chat navigation state: #{e.message}")
    end

    # Broadcast a turn status event (working/completed/error) to the chat session channel
    sig { params(task_run: AiAgentTaskRun, status: String, error: T.nilable(String)).void }
    def broadcast_chat_status(task_run, status, error: nil)
      return unless task_run.mode == "chat_turn"

      chat_session = task_run.chat_session
      return unless chat_session

      data = { type: "status", status: status }
      data[:error] = error if error.present?
      data[:task_run_id] = task_run.id

      ChatSessionChannel.broadcast_to(chat_session, data)
    rescue StandardError => e
      Rails.logger.error("[Internal::AgentRunner] Failed to broadcast chat status: #{e.message}")
    end

    # Broadcast an activity event (navigating, executing) to the chat session channel
    sig { params(task_run: AiAgentTaskRun, step_record: AgentSessionStep).void }
    def broadcast_chat_activity(task_run, step_record)
      return unless task_run.mode == "chat_turn"

      chat_session = task_run.chat_session
      return unless chat_session

      # Don't broadcast activity during setup (before the LLM loop starts).
      # Setup steps (/whoami, saved path restoration) happen before any think step.
      return unless task_run.agent_session_steps.where(step_type: "think").exists?

      text = case step_record.step_type
      when "navigate"
        path = step_record.detail&.dig("path")
        "Navigating to #{path}" if path.present?
      when "execute"
        action = step_record.detail&.dig("action")
        "Executing #{action}" if action.present?
      end
      return unless text

      ChatSessionChannel.broadcast_to(
        chat_session,
        { type: "activity", text: text, task_run_id: task_run.id },
      )
    rescue StandardError => e
      Rails.logger.error("[Internal::AgentRunner] Failed to broadcast chat activity: #{e.message}")
    end

    sig { params(task_run: AiAgentTaskRun, chat_message: ChatMessage).void }
    def track_chat_message_resource(task_run, chat_message)
      AiAgentTaskRunResource.create!(
        ai_agent_task_run: task_run,
        resource: chat_message,
        resource_collective_id: chat_message.collective_id,
        action_type: "message",
      )
    rescue StandardError => e
      Rails.logger.error("[Internal::AgentRunner] Failed to track chat message resource: #{e.message}")
    end

    sig { params(task_run: AiAgentTaskRun, chat_message: ChatMessage).void }
    def broadcast_chat_message(task_run, chat_message)
      chat_session = task_run.chat_session
      return unless chat_session

      ChatSessionChannel.broadcast_to(
        chat_session,
        ChatMessagePresenter.format(chat_message, chat_session),
      )
    rescue StandardError => e
      Rails.logger.error("[Internal::AgentRunner] Failed to broadcast chat message: #{e.message}")
    end

    # After a chat_turn completes, check if the human sent any messages while the
    # turn was running. If so, auto-dispatch a new turn with the latest message.
    sig { params(task_run: AiAgentTaskRun).void }
    def auto_dispatch_next_chat_turn(task_run)
      return unless task_run.mode == "chat_turn"

      chat_session = task_run.chat_session
      return unless chat_session

      # Find the last agent message in this session
      last_agent_message = chat_session.chat_messages
        .where.not(sender_id: chat_session.initiated_by_id)
        .order(created_at: :desc)
        .first

      # Find human messages that arrived after the last agent message
      scope = chat_session.chat_messages.where(sender_id: chat_session.initiated_by_id)
      scope = scope.where("created_at > ?", last_agent_message.created_at) if last_agent_message

      pending_human_message = scope.order(created_at: :desc).first
      return unless pending_human_message

      # Create and dispatch a new turn
      new_run = AiAgentTaskRun.create!(
        tenant: task_run.tenant,
        ai_agent: task_run.ai_agent,
        initiated_by: chat_session.initiated_by,
        task: pending_human_message.content,
        max_steps: 30,
        status: "queued",
        mode: "chat_turn",
        chat_session: chat_session,
        model: task_run.model || "default",
      )

      AgentRunnerDispatchService.dispatch(new_run)
    rescue StandardError => e
      Rails.logger.error("[Internal::AgentRunner] Failed to auto-dispatch chat turn: #{e.message}")
    end

    # Pulls an integer param, coerces, and caps to a sane ceiling to prevent
    # a buggy or compromised runner from skewing billing/reporting.
    TOKEN_COUNT_CAP = 10_000_000
    sig { params(key: Symbol).returns(T.nilable(Integer)) }
    def nonneg_int_param(key)
      raw = params[key]
      return nil if raw.nil?

      n = raw.to_i
      return 0 if n < 0

      [n, TOKEN_COUNT_CAP].min
    end

  end
end
