# typed: true
# frozen_string_literal: true

# Runs the irreversible phase of account deletion: accounts whose grace window
# expired are scrubbed via DataDeletionManager#delete_user!. Per-account
# failures (a sole-admin situation that arose during the grace window, a
# billing outage) are logged and skipped — the account is retried on the next
# run, and the log line is the operator's signal to intervene.
class AccountDeletionScrubJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  sig { void }
  def perform
    AccountDeletionService.scrub_due.find_each { |user| scrub_one(user) }
  end

  sig { params(user: User).void }
  def scrub_one(user)
    # Re-check per account: a restore! landing between the batch query and
    # this user's turn must win.
    user.reload
    return if user.deletion_requested_at.nil? || user.scrubbed_at.present?

    ddm = DataDeletionManager.new(user: user)
    ddm.delete_user!(user: user, confirmation_token: ddm.confirmation_token)
    Rails.logger.info("AccountDeletionScrubJob: scrubbed user #{user.id} (grace window expired)")
  rescue StandardError => e
    Rails.logger.error("AccountDeletionScrubJob: could not scrub user #{user.id}: #{e.message}")
  end
end
