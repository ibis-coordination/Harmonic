# typed: true
# frozen_string_literal: true

module LLMGateway
  # Resolves which Stripe customer pays for a billed LLM call, and verifies the
  # payer is funded. This is the single home for payer-selection policy: an
  # agent funded by an agent_funding collective draws uniformly at random from
  # its funded members' balances; otherwise the individual billing customer
  # pays (the task run's stamped customer, or the agent's own).
  class PayerResolver
    extend T::Sig

    # funding_collective_id names the pool a draw came from (nil when the
    # agent's own billing customer pays) — stamped on the usage ledger for
    # point-in-time attribution, since the agent's pool link is mutable.
    Result = Struct.new(:payer_customer_id, :funding_collective_id, keyword_init: true)

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

    # Resolve the payer for a gateway call made directly by an agent (external
    # ingress — authenticated by its llm_gateway API key, no task run). Same
    # funding policy as the task-run path: funding collective first, else the
    # agent's own billing customer.
    sig { params(agent: User).returns(Result) }
    def self.resolve_for_agent(agent)
      ensure_within_daily_cap!(agent)
      pool_result(agent, context: "agent=#{agent.id}") || funded_result(agent.billing_customer)
    end

    # The agent's own per-UTC-day spend ceiling, whoever pays. Enforced
    # against the usage ledger before any payer is picked.
    sig { params(agent: User).void }
    def self.ensure_within_daily_cap!(agent)
      cap = agent.llm_daily_spend_cap_cents
      return if cap.nil?

      spent = LLMUsageRecord.spend_cents_for({ ai_agent_id: agent.id }, since: Time.current.utc.beginning_of_day)
      return if spent < cap

      raise ResolutionError.new(
        "spend_cap_exceeded",
        :too_many_requests,
        "The agent's daily spend cap has been reached. It resets at midnight UTC."
      )
    end

    # The Stripe customers eligible to pay for this agent's calls: the funding
    # collective's active human members whose own billing is funded (active
    # customer with a prepaid-credit subscription). Members whose funding
    # lapsed are skipped rather than pool-breaking. Lookups use
    # tenant_scoped_only + explicit ids — never collective-scoped associations,
    # which misbehave outside normal request scoping.
    sig { params(agent: User).returns(T::Array[String]) }
    def self.pool_customer_ids(agent)
      collective_id = agent.funding_collective_id
      return [] if collective_id.nil?

      member_user_ids = CollectiveMember.tenant_scoped_only
                                        .where(collective_id: collective_id, archived_at: nil)
                                        .pluck(:user_id)
      human_ids = User.where(id: member_user_ids, user_type: "human").pluck(:id)
      stripe_ids = StripeCustomer.where(billable_type: "User", billable_id: human_ids, active: true)
                                 .where.not(pricing_plan_subscription_id: [nil, ""])
                                 .pluck(:stripe_id)
      under_daily_draw_cap(stripe_ids, collective_id).select { |stripe_id| BalanceGate.funded?(stripe_id) }
    end

    # The collective's per-UTC-day ceiling on drawing from any one member:
    # members it has already tapped for the cap today drop out of the draw
    # (draws by other pools don't count — the ceiling is a promise about THIS
    # collective's reach into a member's balance).
    sig { params(stripe_ids: T::Array[String], collective_id: String).returns(T::Array[String]) }
    def self.under_daily_draw_cap(stripe_ids, collective_id)
      cap = Collective.tenant_scoped_only.find_by(id: collective_id)&.member_daily_draw_cap_cents
      return stripe_ids if cap.nil?

      base = LLMUsageRecord.where(payer_stripe_customer_id: stripe_ids, funding_collective_id: collective_id)
      drawn = base.where(completed_at: Time.current.utc.beginning_of_day..)
                  .group(:payer_stripe_customer_id)
                  .sum(:estimated_cost_cents)
      # In-flight draws hold reservations, same as the flat sums do.
      in_flight = base.where(status: "pending", occurred_at: LLMUsageRecord::PENDING_RESERVATION_WINDOW.ago..)
                      .group(:payer_stripe_customer_id)
                      .count
      reserve = LLMUsageRecord.pending_reserve_cents
      stripe_ids.reject do |stripe_id|
        drawn.fetch(stripe_id, 0) + (in_flight.fetch(stripe_id, 0) * reserve) >= cap
      end
    end

    sig { params(agent: User, context: String).returns(T.nilable(Result)) }
    def self.pool_result(agent, context:)
      return nil if agent.funding_collective_id.nil?

      ensure_funding_collective_available!(agent)
      ensure_primary_active!(agent)

      pool = pool_customer_ids(agent)
      if pool.empty?
        raise ResolutionError.new(
          "pool_exhausted",
          :payment_required,
          "No funded members are available in the agent's funding collective."
        )
      end

      payer = T.must(pool.sample)
      Rails.logger.info("[LLMGateway] Pool payer selected #{context} payer=#{payer} pool_size=#{pool.size}")
      Result.new(payer_customer_id: payer, funding_collective_id: agent.funding_collective_id)
    end

    # Archiving a funding collective is how the arrangement is wound down, so
    # it must stop the spending; membership rows survive archiving, so the
    # member-based checks alone would keep drawing. A collective outside the
    # calling tenant suspends the agent the same way — the membership lookups
    # below are scoped to the calling tenant and could never see it anyway.
    sig { params(agent: User).void }
    def self.ensure_funding_collective_available!(agent)
      collective = Collective.tenant_scoped_only.find_by(id: agent.funding_collective_id)
      return if collective && !collective.archived?

      raise ResolutionError.new(
        "funding_collective_unavailable",
        :forbidden,
        "The agent's funding collective is archived or unavailable; the agent is suspended."
      )
    end

    # No primary, no service: the accountable principal must remain an active
    # member of the funding collective (the attach-time validation can drift —
    # members leave). Checked statelessly on every call.
    sig { params(agent: User).void }
    def self.ensure_primary_active!(agent)
      membership = CollectiveMember.tenant_scoped_only.find_by(
        collective_id: agent.funding_collective_id,
        user_id: agent.parent_id
      )
      return if membership && membership.archived_at.nil?

      raise ResolutionError.new(
        "no_primary",
        :forbidden,
        "The agent's principal is no longer an active member of its funding collective; the agent is suspended."
      )
    end

    # LLM usage must be funded: a prepaid-credit (pricing-plan) subscription
    # must exist, or metered usage would never bill. This is a cheap, local
    # check.
    #
    # The credit *balance* is deliberately NOT fetched here. Payer resolution
    # runs on the per-LLM-call path, and a live Stripe balance call there is
    # both slow and stale (Stripe aggregates deductions rather than deducting
    # in real time), and it conflates a Stripe API error with an empty
    # balance. The balance gate is enforced once at dispatch preflight and,
    # authoritatively, by the gateway relaying a Stripe 402 when the balance
    # is empty.
    sig { params(billing_customer: T.nilable(StripeCustomer)).returns(Result) }
    def self.funded_result(billing_customer)
      if billing_customer.nil? || billing_customer.pricing_plan_subscription_id.blank?
        raise ResolutionError.new(
          "not_funded",
          :payment_required,
          "AI usage billing is not set up. Add credits at /billing."
        )
      end

      unless BalanceGate.funded?(billing_customer.stripe_id)
        raise ResolutionError.new(
          "balance_exhausted",
          :payment_required,
          "The prepaid balance is empty. Add credits at /billing."
        )
      end

      Result.new(payer_customer_id: billing_customer.stripe_id)
    end

    sig { params(task_run: AiAgentTaskRun).void }
    def initialize(task_run)
      @task_run = task_run
    end

    sig { returns(Result) }
    def resolve
      agent = T.must(@task_run.ai_agent)
      self.class.ensure_within_daily_cap!(agent)
      pool = self.class.pool_result(agent, context: "task_run=#{@task_run.id}")
      return pool if pool

      billing_customer = @task_run.billing_customer
      if billing_customer.nil?
        raise ResolutionError.new(
          "not_a_billed_task",
          :unprocessable_entity,
          "Task run has no billing customer; it is not a gateway-billed task."
        )
      end

      self.class.funded_result(billing_customer)
    end
  end
end
