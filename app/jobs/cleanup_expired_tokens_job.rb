# typed: true

class CleanupExpiredTokensJob < ApplicationJob
  extend T::Sig

  queue_as :low_priority

  # Tokens must be expired/deleted for this long before hard deletion
  RETENTION_PERIOD = 30.days

  sig { void }
  def perform
    cutoff = RETENTION_PERIOD.ago

    # Hard delete tokens that have been expired OR soft-deleted for more than RETENTION_PERIOD
    # Using unscoped_for_system_job because this runs outside tenant context
    deleted_count = ApiToken.unscoped_for_system_job
      .where("deleted_at < ? OR expires_at < ?", cutoff, cutoff)
      .delete_all

    Rails.logger.info("CleanupExpiredTokensJob: Deleted #{deleted_count} expired/deleted tokens older than #{RETENTION_PERIOD.inspect}")
  end
end
