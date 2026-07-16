# typed: true
# frozen_string_literal: true

module LLMGateway
  # Resolves which Stripe customer pays for a billed LLM call, and verifies the
  # payer is funded. This is the single home for payer-selection policy: an
  # agent attached to a collective's funding pool draws uniformly at random
  # from the enrolled members' balances; otherwise the individual billing
  # customer pays (the task run's stamped customer, or the agent's own).
  class PayerResolver
    extend T::Sig

    # funding_pool_id names the pool a draw came from (nil when the agent's
    # own billing customer pays) — stamped on the usage ledger for
    # point-in-time attribution, since the agent's pool link is mutable.
    #
    # The remaining fields are the draw's receipt: the ceilings it was
    # authorized against, so a dispute can be settled from the ledger alone
    # rather than reconstructed through the mutable enrollment. All nil on the
    # individual-billing path, where no pool authorized the draw.
    Result = Struct.new(
      :payer_customer_id,
      :funding_pool_id,
      :funding_pool_enrollment_id,
      :enrollment_draw_cap_cents,
      :enrollment_draw_cap_period,
      :pool_member_draw_cap_cents,
      :pool_member_draw_cap_period,
      keyword_init: true,
    )

    # One member eligible to pay for a pool draw, carrying the enrollment terms
    # that authorize it so the selected candidate can be stamped as the draw's
    # receipt without a second lookup.
    Candidate = Struct.new(:stripe_id, :enrollment_id, :cap_cents, :cap_period, keyword_init: true)

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
    # funding policy as the task-run path: funding pool first, else the
    # agent's own billing customer.
    sig { params(agent: User).returns(Result) }
    def self.resolve_for_agent(agent)
      ensure_within_daily_cap!(agent)
      pool_result(agent, context: "agent=#{agent.id}") || funded_result(agent.resolved_billing_customer)
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

    # The Stripe customers eligible to pay for this agent's calls: the pool's
    # actively-enrolled human members who are still active members of the
    # pool's collective, with prepaid-credit-subscribed billing, under the
    # pool's draw ceiling. The $3/month identity subscription (the customer's
    # active flag) is deliberately not required — draws spend prepaid
    # credits. Members whose funding lapsed are skipped rather than
    # pool-breaking. Balances are NOT checked here — the balance gate can
    # reach for Stripe on a stale snapshot, so it runs once against the
    # sampled candidate, not per member. Lookups use tenant_scoped_only +
    # explicit ids — never collective-scoped associations, which misbehave
    # outside normal request scoping.
    sig { params(pool: FundingPool).returns(T::Array[Candidate]) }
    def self.pool_candidates(pool)
      enrollment_caps = FundingPoolEnrollment.tenant_scoped_only
        .where(funding_pool_id: pool.id, archived_at: nil)
        .pluck(:user_id, :id, :draw_cap_cents, :draw_cap_period)
        .to_h { |user_id, id, cents, period| [user_id, [id, cents, period]] }
      member_user_ids = CollectiveMember.tenant_scoped_only
        .where(collective_id: pool.collective_id, user_id: enrollment_caps.keys, archived_at: nil)
        .pluck(:user_id)
      human_ids = User.where(id: member_user_ids, user_type: "human").pluck(:id)
      candidates_by_stripe_id = StripeCustomer.where(billable_type: "User", billable_id: human_ids)
        .where.not(pricing_plan_subscription_id: [nil, ""])
        .pluck(:billable_id, :stripe_id)
        .to_h do |user_id, stripe_id|
          enrollment_id, cents, period = enrollment_caps[user_id]
          [stripe_id, Candidate.new(stripe_id: stripe_id, enrollment_id: enrollment_id, cap_cents: cents, cap_period: period)]
        end
      under_draw_caps(candidates_by_stripe_id, pool)
    end

    # The start of the window a (cents, period) ceiling covers. UTC calendar
    # anchors: midnight, Monday, the 1st.
    sig { params(period: T.nilable(String)).returns(Time) }
    def self.draw_cap_window_start(period)
      now = Time.current.utc
      case period
      when "week" then now.beginning_of_week
      when "month" then now.beginning_of_month
      else now.beginning_of_day
      end
    end

    # The ceilings on drawing from any one member: the pool's ceiling and the
    # member's own enrollment ceiling are enforced independently, each over
    # its own period window — never normalized across periods. A member at
    # either bound drops out of the draw until that window rolls over (draws
    # by other pools don't count — each ceiling is a promise about THIS
    # pool's reach into a member's balance).
    sig { params(candidates_by_stripe_id: T::Hash[String, Candidate], pool: FundingPool).returns(T::Array[Candidate]) }
    def self.under_draw_caps(candidates_by_stripe_id, pool)
      stripe_ids = candidates_by_stripe_id.keys
      return candidates_by_stripe_id.values if stripe_ids.empty?

      periods = ([pool.member_draw_cap_period] + candidates_by_stripe_id.values.map(&:cap_period)).compact.uniq
      base = LLMUsageRecord.where(payer_stripe_customer_id: stripe_ids, funding_pool_id: pool.id)
      drawn_by_period = periods.to_h do |period|
        sums = base.where(completed_at: draw_cap_window_start(period)..)
          .group(:payer_stripe_customer_id)
          .sum(:estimated_cost_cents)
        [period, sums]
      end
      # In-flight draws hold reservations; a recent pending row sits inside
      # every window, so the reservation counts toward each bound.
      in_flight = base.where(status: "pending", occurred_at: LLMUsageRecord::PENDING_RESERVATION_WINDOW.ago..)
        .group(:payer_stripe_customer_id)
        .count
      reserve = LLMUsageRecord.pending_reserve_cents

      candidates_by_stripe_id.values.reject do |candidate|
        reserved = in_flight.fetch(candidate.stripe_id, 0) * reserve
        at_bound = lambda do |cents, period|
          cents && drawn_by_period.fetch(period, {}).fetch(candidate.stripe_id, 0) + reserved >= cents
        end
        at_bound.call(pool.member_draw_cap_cents, pool.member_draw_cap_period) ||
          at_bound.call(candidate.cap_cents, candidate.cap_period)
      end
    end

    sig { params(agent: User, context: String).returns(T.nilable(Result)) }
    def self.pool_result(agent, context:)
      return nil if agent.funding_pool_id.nil?

      pool = ensure_funding_pool_available!(agent)
      ensure_primary_active!(agent, pool)

      candidates = pool_candidates(pool)
      # Sample first, verify the balance of only the sampled member (falling
      # through to the next on a dry balance): the gate can reach for Stripe
      # on a stale snapshot, so verifying the whole pool would put one Stripe
      # round-trip per member on the per-call path. A funded pool costs one
      # check; the worst case (everyone dry) still checks each member once.
      payer = candidates.shuffle.find { |candidate| BalanceGate.funded?(candidate.stripe_id) }
      if payer.nil?
        raise ResolutionError.new(
          "pool_exhausted",
          :payment_required,
          "No funded members are available in the agent's funding pool."
        )
      end

      Rails.logger.info("[LLMGateway] Pool payer selected #{context} payer=#{payer.stripe_id} pool_size=#{candidates.size}")
      Result.new(
        payer_customer_id: payer.stripe_id,
        funding_pool_id: pool.id,
        funding_pool_enrollment_id: payer.enrollment_id,
        enrollment_draw_cap_cents: payer.cap_cents,
        enrollment_draw_cap_period: payer.cap_period,
        pool_member_draw_cap_cents: pool.member_draw_cap_cents,
        pool_member_draw_cap_period: pool.member_draw_cap_period,
      )
    end

    # Closing a pool (or archiving its collective) is how the arrangement is
    # wound down, so it must stop the spending; enrollment rows survive both,
    # so the member-based checks alone would keep drawing. Pool availability
    # (Collective#funding_pools_available?) is checked here too: losing it —
    # operator flag turned off, paid tier lapsed — must stop draws
    # immediately, not just hide the UI. A pool outside the calling tenant
    # suspends the agent the same way — the enrollment lookups are scoped to
    # the calling tenant and could never see it anyway. The wire code
    # predates the pool remodel and is kept stable for callers.
    sig { params(agent: User).returns(FundingPool) }
    def self.ensure_funding_pool_available!(agent)
      pool = FundingPool.tenant_scoped_only.find_by(id: agent.funding_pool_id)
      collective = pool && Collective.tenant_scoped_only.find_by(id: pool.collective_id)
      if pool && !pool.archived? && collective && !collective.archived? && collective.funding_pools_available?
        return pool
      end

      raise ResolutionError.new(
        "funding_collective_unavailable",
        :forbidden,
        "The agent's funding pool is closed or unavailable, so its calls are refused. It runs again when the pool reopens, or when it is detached and given its own billing."
      )
    end

    # No primary, no service: the accountable principal must remain enrolled
    # in the pool and an active member of its collective (the attach-time
    # validation can drift — members withdraw or leave). Checked statelessly
    # on every call.
    sig { params(agent: User, pool: FundingPool).void }
    def self.ensure_primary_active!(agent, pool)
      return if collective_principaled?(agent, pool)

      enrollment = FundingPoolEnrollment.tenant_scoped_only.find_by(
        funding_pool_id: pool.id,
        user_id: agent.parent_id,
        archived_at: nil
      )
      membership = CollectiveMember.tenant_scoped_only.find_by(
        collective_id: pool.collective_id,
        user_id: agent.parent_id
      )
      return if enrollment && membership && membership.archived_at.nil?

      raise ResolutionError.new(
        "no_primary",
        :forbidden,
        "The agent's principal is no longer enrolled in its funding pool, so its calls are refused until the principal re-enrolls or the agent is detached."
      )
    end

    # A system-role agent principaled by the pool collective's own identity
    # is the collective's agent: enrolling is consent that the pool funds
    # this collective's agents, so there is no member-principal to
    # re-verify. A pool with no fundable members still fails as
    # pool_exhausted.
    sig { params(agent: User, pool: FundingPool).returns(T::Boolean) }
    def self.collective_principaled?(agent, pool)
      return false unless agent.system? && agent.parent_id.present?

      Collective.tenant_scoped_only.exists?(id: pool.collective_id, identity_user_id: agent.parent_id)
    end

    # LLM usage must be funded: a prepaid-credit (pricing-plan) subscription
    # must exist, or metered usage would never bill. This is a cheap, local
    # check.
    #
    # The balance check goes through BalanceGate: normally a cached snapshot
    # minus the local ledger delta, with Stripe consulted only on a snapshot
    # miss or TTL expiry — never a per-call fetch (a live call here would be
    # slow and stale, since Stripe aggregates deductions rather than
    # deducting in real time). The gateway relaying a Stripe 402 remains the
    # authoritative backstop.
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
