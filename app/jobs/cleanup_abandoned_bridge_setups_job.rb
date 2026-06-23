# typed: true
# frozen_string_literal: true

# Sweeps for HarmonicBridgeSetup rows that were redeemed (token + rule
# minted) but never finalized, where the setup itself has expired.
#
# Without this job, a `harmonic-bridge add` that GETs the setup URL but
# never completes the POST leaves a 1-year ApiToken and a disabled
# AutomationRule parked in the DB with no UI handle to find or revoke.
#
# Eligible rows: redeemed_at IS NOT NULL AND webhook_registered_at IS NULL
# AND expires_at < now. The cleanup mirrors revert_completion!: destroy
# the rule, destroy the token, then destroy the setup row.
#
# Runs hourly via sidekiq-cron.
class CleanupAbandonedBridgeSetupsJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  sig { void }
  def perform
    abandoned = HarmonicBridgeSetup.unscoped_for_system_job
      .where.not(redeemed_at: nil)
      .where(webhook_registered_at: nil)
      .where(expires_at: ...Time.current)

    count = 0
    abandoned.find_each do |setup|
      ActiveRecord::Base.transaction do
        rule = AutomationRule.unscoped_for_system_job.find_by(id: setup.automation_rule_id)
        token = ApiToken.unscoped_for_system_job.find_by(id: setup.api_token_id)
        setup.destroy!
        rule&.destroy!
        token&.destroy!
      end
      count += 1
    end

    Rails.logger.info("CleanupAbandonedBridgeSetupsJob: swept #{count} abandoned bridge setup(s)") if count.positive?
  end
end
