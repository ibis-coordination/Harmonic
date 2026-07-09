# typed: true
# frozen_string_literal: true

# Internal API for the LLM gateway service.
# Inherits IP restriction, HMAC verification, and tenant resolution from BaseController.
module Internal
  class LLMGatewayController < BaseController
    extend T::Sig

    # POST /internal/llm-gateway/select-payer
    # Given the task run behind a billed LLM call, resolve the Stripe customer
    # that should pay for it (and verify that payer is funded).
    sig { void }
    def select_payer
      task_run = AiAgentTaskRun.find_by(id: params[:task_run_id])
      if task_run.nil?
        render json: { error: "Task run not found" }, status: :not_found
        return
      end

      result = LLMGateway::PayerResolver.resolve(task_run)
      render json: { payer_customer_id: result.payer_customer_id }
    rescue LLMGateway::PayerResolver::ResolutionError => e
      render json: { error: e.code }, status: e.http_status
    end
  end
end
