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

      current_steps = task_run.steps_data || []
      new_steps = steps.map do |s|
        {
          type: s[:type],
          detail: s[:detail],
          timestamp: s[:timestamp],
        }
      end

      task_run.update!(
        steps_data: current_steps + new_steps,
        steps_count: (task_run.steps_count || 0) + new_steps.length,
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
      steps_count = nonneg_int_param(:steps_count)

      task_run.update!(
        status: params[:success] ? "completed" : "failed",
        success: params[:success] || false,
        final_message: params[:final_message],
        error: params[:error],
        steps_data: params[:steps_data].is_a?(Array) ? params[:steps_data] : task_run.steps_data,
        steps_count: steps_count.nil? ? task_run.steps_count : steps_count,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens,
        completed_at: Time.current,
      )

      destroy_task_token(task_run)
      task_run.notify_parent_automation_runs!

      render json: { status: "ok" }
    end

    # POST /internal/agent-runner/tasks/:id/fail
    sig { void }
    def fail
      task_run = find_task_run!
      return unless guard_terminal_transition!(task_run)

      task_run.update!(
        status: "failed",
        success: false,
        error: params[:error],
        completed_at: Time.current,
      )

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
        .where(ai_agent_task_run_id: task_run.id, internal: true)
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
