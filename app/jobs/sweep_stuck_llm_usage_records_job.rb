# typed: true
# frozen_string_literal: true

# Reconciles LLM usage ledger rows stuck in "pending" — calls whose usage
# never landed cleanly. Without this sweep such rows count as zero spend
# forever (after the 15-minute reservation window) even though Stripe billed
# the call, so every ledger-derived number — draw ceilings, spend caps,
# usage transparency views — silently undercounts.
#
# Two passes:
# 1. Re-price: rows whose token counts landed but couldn't be priced at
#    report time (rate-card gap, catalog outage) are costed now if the
#    catalog can price them, anchored at sweep time like any completion.
# 2. Abandon: rows still pending past ABANDON_THRESHOLD are marked
#    "abandoned" — a terminal, zero-cost verdict that keeps them visible to
#    ops without faking a price. A late usage report can still complete them.
#
# Each run logs a counts line; a nonzero abandoned count is the signal that
# billed usage escaped the ledger and deserves a look.
#
# Runs hourly via sidekiq-cron.
class SweepStuckLLMUsageRecordsJob < SystemJob
  extend T::Sig

  ABANDON_THRESHOLD = 24.hours

  sig { void }
  def perform
    repriced = reprice_unpriced_rows
    abandoned = abandon_stale_rows
    still_pending = LLMUsageRecord.where(status: "pending").count
    Rails.logger.info(
      "[SweepStuckLLMUsageRecords] repriced=#{repriced} abandoned=#{abandoned} still_pending=#{still_pending}",
    )
  end

  private

  sig { returns(Integer) }
  def reprice_unpriced_rows
    count = 0
    LLMUsageRecord.where(status: "pending").where.not(input_tokens: nil).find_each do |record|
      cost = LLMGateway::UsageCost.estimate_cents(
        model: record.model,
        input_tokens: T.must(record.input_tokens),
        output_tokens: record.output_tokens.to_i,
      )
      next if cost.nil?

      # Anchored at sweep time, consistent with record-usage: the cost belongs
      # to the moment it became known.
      record.update!(status: "completed", estimated_cost_cents: cost, completed_at: Time.current)
      count += 1
    end
    count
  end

  sig { returns(Integer) }
  def abandon_stale_rows
    count = 0
    LLMUsageRecord.where(status: "pending").where(occurred_at: ...ABANDON_THRESHOLD.ago).find_each do |record|
      record.update!(status: "abandoned")
      Rails.logger.warn(
        "[SweepStuckLLMUsageRecords] Abandoned #{record.selection_id} " \
        "(agent=#{record.ai_agent_id}, payer=#{record.payer_stripe_customer_id}, model=#{record.model.inspect}, " \
        "tokens=#{record.input_tokens.inspect}/#{record.output_tokens.inspect}, occurred_at=#{record.occurred_at}) — " \
        "usage never landed; Stripe may have billed this call without a ledger cost.",
      )
      count += 1
    end
    count
  end
end
