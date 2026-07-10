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
      render json: { payer_customer_id: result.payer_customer_id }
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
      render json: { payer_customer_id: result.payer_customer_id, model: model }
    rescue LLMGateway::PayerResolver::ResolutionError => e
      render_openai_error(e.http_status, e.code, e.message)
    rescue StripeGatewayModelMapper::UnmappedModelError => e
      render_openai_error(:bad_request, "unsupported_model", e.message)
    end

    private

    sig { params(status: Symbol, code: String, message: String).void }
    def render_openai_error(status, code, message)
      render json: { error: { message: message, type: "invalid_request_error", code: code } }, status: status
    end
  end
end
