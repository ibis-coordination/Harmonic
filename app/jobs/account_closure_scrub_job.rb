# typed: true
# frozen_string_literal: true

# Runs the irreversible phase of account closure: accounts whose grace window
# expired are scrubbed via DataDeletionManager#delete_user!. Per-account
# failures (a sole-admin situation that arose during the grace window, a
# billing outage) are logged and skipped — the account is retried on the next
# run, and the log line is the operator's signal to intervene.
class AccountClosureScrubJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  sig { void }
  def perform
    AccountClosureService.scrub_due.find_each do |user|
      ddm = DataDeletionManager.new(user: user)
      ddm.delete_user!(user: user, confirmation_token: ddm.confirmation_token)
      Rails.logger.info("AccountClosureScrubJob: scrubbed user #{user.id} (grace window expired)")
    rescue StandardError => e
      Rails.logger.error("AccountClosureScrubJob: could not scrub user #{user.id}: #{e.message}")
    end
  end
end
