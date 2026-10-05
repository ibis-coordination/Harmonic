# typed: true
# frozen_string_literal: true

# Deletes agent signups that were never claimed and have been expired for
# longer than the retention period. Starting a signup needs no account and
# creates a row every time, including for emails that match no member, so
# unclaimed rows would otherwise accumulate without bound.
#
# Claimed and redeemed signups are kept: they are the record of how an agent
# arrived, and there is at most one per agent.
class CleanupExpiredAgentSignupsJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  RETENTION_PERIOD = 30.days

  sig { void }
  def perform
    deleted_count = AgentSignup.unscoped_for_system_job
      .where(state: ["pending", "declined"])
      .where(expires_at: ...RETENTION_PERIOD.ago)
      .delete_all

    Rails.logger.info(
      "CleanupExpiredAgentSignupsJob: Deleted #{deleted_count} unclaimed agent signups " \
      "expired for more than #{RETENTION_PERIOD.inspect}"
    )
  end
end
