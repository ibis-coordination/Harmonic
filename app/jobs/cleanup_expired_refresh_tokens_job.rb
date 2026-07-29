# typed: true
# frozen_string_literal: true

# Deletes refresh tokens that have been expired for longer than the retention
# period. Rotated and revoked rows are kept until then too: a rotated
# predecessor is what makes token-reuse (theft) detection work, so rows are
# only removed once they have been unusable for the full grace window.
class CleanupExpiredRefreshTokensJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  RETENTION_PERIOD = 30.days

  sig { void }
  def perform
    deleted_count = RefreshToken
      .where(expires_at: ...RETENTION_PERIOD.ago)
      .delete_all

    Rails.logger.info("CleanupExpiredRefreshTokensJob: Deleted #{deleted_count} refresh tokens expired for more than #{RETENTION_PERIOD.inspect}")
  end
end
