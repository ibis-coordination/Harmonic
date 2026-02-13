# typed: true
# frozen_string_literal: true

# Safety net job to clean up expired internal tokens.
#
# Internal tokens should be deleted immediately after their task run completes,
# but this job catches any orphaned tokens from crashed runs or other failures.
# Unlike external tokens (30-day retention), internal tokens are cleaned up
# immediately after expiry since they're only meant to exist during active runs.
#
# Schedule via cron/whenever to run hourly.
class CleanupExpiredInternalTokensJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  sig { void }
  def perform
    # Delete internal tokens that have expired (safety net for crashed runs)
    # Using unscoped_for_system_job to bypass tenant scope, then filtering to internal tokens
    deleted_count = ApiToken.unscoped_for_system_job
      .unscope(where: :internal) # Bypass the external-only default scope on ApiToken
      .where(internal: true)
      .where(expires_at: ...Time.current)
      .delete_all

    Rails.logger.info("CleanupExpiredInternalTokensJob: Deleted #{deleted_count} expired internal tokens") if deleted_count.positive?
  end
end
