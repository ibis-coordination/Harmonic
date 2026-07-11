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
  belongs_to :funding_collective, class_name: "Collective", optional: true
  belongs_to :task_run, class_name: "AiAgentTaskRun", foreign_key: "ai_agent_task_run_id", optional: true, inverse_of: false
  belongs_to :api_token, optional: true

  validates :selection_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :payer_stripe_customer_id, presence: true
  validates :occurred_at, presence: true

  scope :completed, -> { where(status: "completed") }

  sig { returns(T::Boolean) }
  def pending?
    status == "pending"
  end
end
