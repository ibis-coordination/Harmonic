# typed: true
# frozen_string_literal: true

# One billed LLM call: opened as "pending" when select-payer picks the payer,
# completed with token counts and estimated cost by record-usage after the
# response (rows stuck pending are calls whose usage never came back —
# gateway crash, client disconnect). This ledger feeds the balance gate's
# local delta, spend caps, and per-agent accounting; Stripe remains the
# billing source of truth.
#
# NOT tenant-scoped, by design (carries origin_tenant_id, not tenant_id):
# balance gating sums a payer's spend across every tenant they fund agents
# in, the same way StripeCustomer sits outside tenant scoping.
class LLMUsageRecord < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"

  STATUSES = ["pending", "completed", "failed"].freeze

  belongs_to :origin_tenant, class_name: "Tenant"
  belongs_to :ai_agent, class_name: "User"
  # The pool the draw came from, stamped at selection time (nil = the agent's
  # own billing customer paid). Point-in-time: agents move between pools, so
  # this is never re-derived through the agent's mutable link.
  belongs_to :funding_pool, optional: true
  belongs_to :task_run, class_name: "AiAgentTaskRun", foreign_key: "ai_agent_task_run_id", optional: true, inverse_of: false
  belongs_to :api_token, optional: true

  validates :selection_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :payer_stripe_customer_id, presence: true
  validates :occurred_at, presence: true

  scope :completed, -> { where(status: "completed") }

  # An in-flight call's cost is unknown until record-usage lands it, so spend
  # sums treat each recent pending row as a fixed reservation — otherwise any
  # number of concurrent calls pass the caps and the balance gate while their
  # costs are all still NULL. Rows pending past the window are calls whose
  # usage never came back; they stop reserving rather than pinning the payer
  # at zero forever.
  PENDING_RESERVATION_WINDOW = 15.minutes

  sig { returns(Integer) }
  def self.pending_reserve_cents
    ENV.fetch("GATEWAY_PENDING_RESERVE_CENTS", "25").to_i
  end

  # Spend attributed to the period starting at `since`, for the rows matching
  # `filters`: costs that landed in the period plus a reservation for each
  # recent still-pending call. Pending rows are counted by the reservation
  # window alone, not by `since` — an in-flight call reserves no matter when
  # the period started (its cost, once known, will land inside the period).
  sig do
    params(
      filters: T::Hash[Symbol, T.untyped],
      since: T.any(Time, ActiveSupport::TimeWithZone),
    ).returns(Numeric)
  end
  def self.spend_cents_for(filters, since:)
    scoped = where(filters)
    landed = scoped.where(completed_at: since..).sum(:estimated_cost_cents)
    pending_calls = scoped.where(status: "pending", occurred_at: PENDING_RESERVATION_WINDOW.ago..).count
    landed + (pending_calls * pending_reserve_cents)
  end

  sig { returns(T::Boolean) }
  def pending?
    status == "pending"
  end
end
