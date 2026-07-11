# typed: true
# frozen_string_literal: true

# Internal API for the LLM gateway service.
# Inherits IP restriction, HMAC verification, and tenant resolution from BaseController.
module Internal
  class LLMGatewayController < BaseController
    extend T::Sig

    # The token caller arrives via the public llm.<hostname> edge, so there is
    # no tenant subdomain to resolve — the token itself carries the tenant and
    # the action scopes the thread to it after authentication.
    skip_before_action :resolve_tenant_from_subdomain, only: :select_payer_for_token

    # POST /internal/llm-gateway/select-payer
    # Given the task run behind a billed LLM call, resolve the Stripe customer
    # that should pay for it (and verify that payer is funded).
    sig { void }
    def select_payer
      # Eager-load the payer: this runs once per LLM call, so the lazy
      # belongs_to would double the query count on a hot path.
      task_run = AiAgentTaskRun.includes(:billing_customer).find_by(id: params[:task_run_id])
      if task_run.nil?
        render json: { error: "Task run not found" }, status: :not_found
        return
      end

      result = LLMGateway::PayerResolver.resolve(task_run)
      selection_id = open_usage_record(
        ai_agent_id: T.must(task_run.ai_agent_id),
        payer_customer_id: result.payer_customer_id,
        origin_tenant_id: T.must(task_run.tenant_id),
        funding_collective_id: result.funding_collective_id,
        task_run_id: task_run.id,
      )
      render json: { payer_customer_id: result.payer_customer_id, selection_id: selection_id }
    rescue LLMGateway::PayerResolver::ResolutionError => e
      render json: { error: e.code }, status: e.http_status
    end

    # POST /internal/llm-gateway/select-payer-for-token
    # Given an agent's llm_gateway API key (a gateway call made directly by an
    # external agent, no task run), authenticate it and resolve the payer via
    # the agent's own funding mapping. Error bodies are OpenAI-shaped because
    # the gateway passes them through to the external client verbatim.
    sig { void }
    def select_payer_for_token
      token = ApiToken.authenticate_llm_gateway(params[:agent_token].to_s)
      if token.nil? || token.expired?
        render_openai_error(:unauthorized, "invalid_token", "Invalid or expired API key.")
        return
      end

      tenant = Tenant.scope_thread_to_tenant(subdomain: T.must(token.tenant).subdomain)
      unless tenant.feature_enabled?("llm_gateway")
        render_openai_error(:forbidden, "feature_disabled", "LLM gateway access is not enabled for this account.")
        return
      end

      result = LLMGateway::PayerResolver.resolve_for_agent(T.must(token.user))
      model = StripeGatewayModelMapper.map(params[:model])

      token.token_used!
      selection_id = open_usage_record(
        ai_agent_id: T.must(token.user_id),
        payer_customer_id: result.payer_customer_id,
        origin_tenant_id: tenant.id,
        funding_collective_id: result.funding_collective_id,
        api_token_id: token.id,
        model: model,
      )
      render json: { payer_customer_id: result.payer_customer_id, model: model, selection_id: selection_id }
    rescue LLMGateway::PayerResolver::ResolutionError => e
      render_openai_error(e.http_status, e.code, e.message)
    rescue StripeGatewayModelMapper::UnmappedModelError => e
      render_openai_error(:bad_request, "unsupported_model", e.message)
    end

    # POST /internal/llm-gateway/record-usage
    # Completes the pending usage record the selection opened: token counts
    # from the gateway, cost estimated here (pricing stays in Rails).
    # Idempotent on selection_id — gateway retries must not double-record.
    sig { void }
    def record_usage
      record = LLMUsageRecord.find_by(selection_id: params[:selection_id].to_s)
      if record.nil?
        render json: { error: "unknown_selection" }, status: :not_found
        return
      end
      unless record.pending?
        render json: { status: record.status }
        return
      end

      model = params[:model].presence || record.model
      input_tokens = params[:input_tokens].to_i
      output_tokens = params[:output_tokens].to_i
      ok = params[:status].to_s == "ok"
      cost = LLMGateway::UsageCost.estimate_cents(
        model: model, input_tokens: input_tokens, output_tokens: output_tokens,
      )

      # Billed usage that can't be priced (catalog outage, rate-card gap) must
      # not seal at a NULL cost — the spend sums would count it as free
      # forever. Keep the tokens and stay pending so a later report can price
      # it. Failed calls billed nothing, so they finalize regardless.
      if ok && cost.nil?
        record.update!(model: model, input_tokens: input_tokens, output_tokens: output_tokens)
        Rails.logger.warn("[LLMGateway] Usage for #{record.selection_id} is unpriced (model=#{model}); leaving pending for re-pricing")
        render json: { status: record.status }
        return
      end

      record.update!(
        status: ok ? "completed" : "failed",
        model: model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        estimated_cost_cents: cost,
        # Spend sums anchor on completion: the cost belongs to the moment it
        # became known, or a call straddling a snapshot refresh or a UTC-day
        # boundary would be counted nowhere.
        completed_at: Time.current,
      )
      render json: { status: record.status }
    end

    private

    # Opens the pending ledger row for a resolved selection. The ledger is
    # advisory (gating/accounting) — a failure to open it must not block the
    # billed call itself, so this logs and returns nil rather than raising;
    # the gateway skips record-usage when no selection id came back.
    sig do
      params(
        ai_agent_id: String,
        payer_customer_id: String,
        origin_tenant_id: String,
        funding_collective_id: T.nilable(String),
        task_run_id: T.nilable(String),
        api_token_id: T.nilable(String),
        model: T.nilable(String),
      ).returns(T.nilable(String))
    end
    def open_usage_record(ai_agent_id:, payer_customer_id:, origin_tenant_id:, funding_collective_id: nil,
                          task_run_id: nil, api_token_id: nil, model: nil)
      record = LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: "pending",
        ai_agent_id: ai_agent_id,
        payer_stripe_customer_id: payer_customer_id,
        origin_tenant_id: origin_tenant_id,
        funding_collective_id: funding_collective_id,
        ai_agent_task_run_id: task_run_id,
        api_token_id: api_token_id,
        model: model,
        occurred_at: Time.current,
      )
      record.selection_id
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("[LLMGateway] Failed to open usage record (agent=#{ai_agent_id}): #{e.class} #{e.message}")
      nil
    end

    sig { params(status: Symbol, code: String, message: String).void }
    def render_openai_error(status, code, message)
      render json: { error: { message: message, type: "invalid_request_error", code: code } }, status: status
    end
  end
end
