# typed: true
# frozen_string_literal: true

module LLMGateway
  # Read-only usage rollups over the LLM usage ledger, for the two transparency
  # surfaces: a funding pool's page (who spent from the pool, and on which
  # agents) and a member's billing page (which pools they fund, and which of
  # their agents spent their credits). All cost sums are over completed rows
  # within the reporting window — pending rows carry no cost, so they surface
  # only as counts.
  class UsageReport
    extend T::Sig

    WINDOW = 30.days

    sig { params(pool: FundingPool, window: ActiveSupport::Duration).returns(T::Hash[Symbol, T.untyped]) }
    def self.pool_report(pool, window: WINDOW)
      completed = LLMUsageRecord.completed.where(funding_pool_id: pool.id, completed_at: window.ago..)
      spend_by_customer = completed.group(:payer_stripe_customer_id).sum(:estimated_cost_cents)
      spend_by_agent = completed.group(:ai_agent_id).sum(:estimated_cost_cents)

      pending = LLMUsageRecord.where(funding_pool_id: pool.id, status: "pending")

      {
        total_cents: spend_by_customer.values.sum,
        member_rows: pool_member_rows(pool, spend_by_customer),
        agent_rows: agent_rows(spend_by_agent),
        pending_count: pending.count,
        stale_pending_count: pending.where(occurred_at: ...LLMUsageRecord::PENDING_RESERVATION_WINDOW.ago).count,
      }
    end

    sig { params(user: User, window: ActiveSupport::Duration).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def self.funding_report(user, window: WINDOW)
      customer = user.stripe_customer
      return nil if customer.nil?

      completed = LLMUsageRecord.completed.where(payer_stripe_customer_id: customer.stripe_id, completed_at: window.ago..)
      pool_draws = completed.where.not(funding_pool_id: nil)
      drawn_by_pool = pool_draws.group(:funding_pool_id).sum(:estimated_cost_cents)
      spend_by_agent = completed.group(:ai_agent_id).sum(:estimated_cost_cents)

      {
        enrollment_rows: funding_enrollment_rows(user, drawn_by_pool),
        agent_rows: agent_rows(spend_by_agent),
        total_billed_cents: completed.sum(:estimated_cost_cents),
        pool_draw_cents: pool_draws.sum(:estimated_cost_cents),
      }
    end

    # One row per active enrollment (zero-spend members included), plus a row
    # for any customer with window spend who is no longer actively enrolled
    # (withdrawn members whose past draws still show up). Sorted by spend, then
    # name.
    sig do
      params(pool: FundingPool, spend_by_customer: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]])
    end
    def self.pool_member_rows(pool, spend_by_customer)
      enrolled_user_ids = FundingPoolEnrollment.tenant_scoped_only(pool.tenant_id)
        .where(funding_pool_id: pool.id, archived_at: nil)
        .pluck(:user_id)
      users_by_id = User.where(id: enrolled_user_ids).index_by(&:id)
      stripe_id_by_user = StripeCustomer.where(billable_type: "User", billable_id: enrolled_user_ids)
        .pluck(:billable_id, :stripe_id).to_h
      enrolled_stripe_ids = stripe_id_by_user.values

      rows = enrolled_user_ids.filter_map do |user_id|
        user = users_by_id[user_id]
        next if user.nil?

        stripe_id = stripe_id_by_user[user_id]
        spend = (stripe_id && spend_by_customer[stripe_id]) || 0
        { user: user, spend_cents: spend }
      end

      withdrawn_stripe_ids = spend_by_customer.keys - enrolled_stripe_ids
      user_id_by_stripe_id = StripeCustomer.where(billable_type: "User", stripe_id: withdrawn_stripe_ids)
        .pluck(:stripe_id, :billable_id).to_h
      withdrawn_users = User.where(id: user_id_by_stripe_id.values).index_by(&:id)
      withdrawn_stripe_ids.each do |stripe_id|
        user = withdrawn_users[user_id_by_stripe_id[stripe_id]]
        next if user.nil?

        rows << { user: user, spend_cents: spend_by_customer[stripe_id] }
      end

      rows.sort_by { |row| [-row[:spend_cents], row[:user].display_name.to_s] }
    end

    # The user's active enrollments across every tenant, each with the amount
    # this pool has drawn from the user in the window. Pool and collective are
    # loaded by explicit tenant scope — associations off a cross-tenant row
    # misbehave under the current request's scoping.
    sig { params(user: User, drawn_by_pool: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.funding_enrollment_rows(user, drawn_by_pool)
      FundingPoolEnrollment.for_user_across_tenants(user).active.map do |enrollment|
        pool = FundingPool.tenant_scoped_only(enrollment.tenant_id).find_by(id: enrollment.funding_pool_id)
        collective = pool && Collective.tenant_scoped_only(enrollment.tenant_id).find_by(id: pool.collective_id)
        {
          enrollment: enrollment,
          pool_name_or_collective_name: collective&.name,
          drawn_cents: drawn_by_pool[enrollment.funding_pool_id] || 0,
        }
      end
    end

    # Agents with any completed spend in the grouped scope, spend descending.
    sig { params(spend_by_agent: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.agent_rows(spend_by_agent)
      agents_by_id = User.where(id: spend_by_agent.keys).index_by(&:id)
      rows = spend_by_agent.filter_map do |agent_id, spend|
        agent = agents_by_id[agent_id]
        next if agent.nil? || spend.to_f <= 0

        { agent: agent, spend_cents: spend }
      end
      rows.sort_by { |row| -row[:spend_cents] }
    end
  end
end
