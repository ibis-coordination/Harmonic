# typed: true
# frozen_string_literal: true

module LLMGateway
  # Resolves which Stripe customer pays for a billed LLM call, and verifies the
  # payer is funded. This is the single home for payer-selection policy: today
  # it resolves a task run to its stamped billing customer (one payer); the
  # common-pool selection will extend this same seam.
  class PayerResolver
    extend T::Sig

    Result = Struct.new(:payer_customer_id, keyword_init: true)

    # A resolution failure that carries the wire error code and HTTP status the
    # gateway (and its callers) should surface.
    class ResolutionError < StandardError
      extend T::Sig

      sig { returns(String) }
      attr_reader :code

      sig { returns(Symbol) }
      attr_reader :http_status

      sig { params(code: String, http_status: Symbol, message: String).void }
      def initialize(code, http_status, message)
        @code = code
        @http_status = http_status
        super(message)
      end
    end

    sig { params(task_run: AiAgentTaskRun).returns(Result) }
    def self.resolve(task_run)
      new(task_run).resolve
    end

    sig { params(task_run: AiAgentTaskRun).void }
    def initialize(task_run)
      @task_run = task_run
    end

    sig { returns(Result) }
    def resolve
      billing_customer = @task_run.billing_customer
      if billing_customer.nil?
        raise ResolutionError.new(
          "not_a_billed_task",
          :unprocessable_entity,
          "Task run has no billing customer; it is not a gateway-billed task."
        )
      end

      # LLM usage must be funded: a prepaid-credit (pricing-plan) subscription
      # must exist, or metered usage would never bill. This is a cheap, local
      # check.
      #
      # The credit *balance* is deliberately NOT fetched here. `select_payer`
      # runs on the per-LLM-call path, and a live Stripe balance call there is
      # both slow and stale (Stripe aggregates deductions rather than deducting
      # in real time), and it conflates a Stripe API error with an empty
      # balance. The balance gate is enforced once at dispatch preflight and,
      # authoritatively, by the gateway relaying a Stripe 402 when the balance
      # is empty.
      if billing_customer.pricing_plan_subscription_id.blank?
        raise ResolutionError.new(
          "not_funded",
          :payment_required,
          "AI usage billing is not set up. Add credits at /billing."
        )
      end

      Result.new(payer_customer_id: billing_customer.stripe_id)
    end
  end
end
