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
    self.class.tenant_scrub_due.find_each { |tenant_user| scrub_one_tenant_user(tenant_user) }
    # Reminders go out AFTER the scrub passes so a just-scrubbed account never
    # gets a reminder for a deletion that already happened.
    send_reminders
  end

  # Per-subdomain slices whose grace window has expired. Only the principal's
  # rows are selected: agent slices scrub as part of their principal's, and
  # users pending GLOBAL deletion are handled by scrub_due (the global request
  # superseded any per-subdomain one).
  sig { returns(T.untyped) }
  def self.tenant_scrub_due
    TenantUser.unscoped_for_system_job
      .where(deletion_requested_at: ..AccountDeletionService::GRACE_PERIOD.ago, scrubbed_at: nil)
      .joins(:user)
      .where(users: { user_type: "human", deletion_requested_at: nil, scrubbed_at: nil })
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

  # One reminder per deletion request, REMINDER_LEAD before the scrub. The
  # sent-at stamp (cleared on each new request) makes this idempotent across
  # runs, including runs delayed past the intended reminder day.
  sig { void }
  def send_reminders
    cutoff = (AccountDeletionService::GRACE_PERIOD - AccountDeletionService::REMINDER_LEAD).ago

    User.where(deletion_requested_at: ..cutoff, scrubbed_at: nil, deletion_reminder_sent_at: nil)
      .find_each do |user|
      tenant = TenantUser.for_user_across_tenants(user).first&.tenant
      next if tenant.nil?

      AccountDeletionMailer.deletion_reminder(
        user: user, tenant: tenant,
        scrub_date: (T.must(user.deletion_requested_at) + AccountDeletionService::GRACE_PERIOD).to_date,
      ).deliver_later
      user.update!(deletion_reminder_sent_at: Time.current)
    rescue StandardError => e
      Rails.logger.error("AccountDeletionScrubJob: could not send reminder for user #{user.id}: #{e.message}")
    end

    TenantUser.unscoped_for_system_job
      .where(deletion_requested_at: ..cutoff, scrubbed_at: nil, deletion_reminder_sent_at: nil)
      .joins(:user)
      .where(users: { user_type: "human", deletion_requested_at: nil, scrubbed_at: nil })
      .find_each do |tenant_user|
      AccountDeletionMailer.deletion_reminder(
        user: User.find(tenant_user.user_id), tenant: Tenant.find(tenant_user.tenant_id),
        scrub_date: (T.must(tenant_user.deletion_requested_at) + AccountDeletionService::GRACE_PERIOD).to_date,
        subdomain_only: true,
      ).deliver_later
      tenant_user.update!(deletion_reminder_sent_at: Time.current)
    rescue StandardError => e
      Rails.logger.error("AccountDeletionScrubJob: could not send reminder for tenant slice #{tenant_user.id}: #{e.message}")
    end
  end

  sig { params(tenant_user: TenantUser).void }
  def scrub_one_tenant_user(tenant_user)
    # Same restore-wins re-check as scrub_one, for one tenant's slice. A global
    # request landing mid-batch also wins: the user-level scrub owns that case.
    tenant_user.reload
    return if tenant_user.deletion_requested_at.nil? || tenant_user.scrubbed_at.present?

    user = User.find(tenant_user.user_id)
    return if user.deletion_requested_at.present? || user.scrubbed_at.present?

    tenant = Tenant.find(tenant_user.tenant_id)
    ddm = DataDeletionManager.new(user: user)
    ddm.delete_tenant_user!(user: user, tenant: tenant, confirmation_token: ddm.confirmation_token)
    Rails.logger.info("AccountDeletionScrubJob: scrubbed tenant slice #{tenant_user.id} (grace window expired)")
  rescue StandardError => e
    Rails.logger.error("AccountDeletionScrubJob: could not scrub tenant slice #{tenant_user.id}: #{e.message}")
  end
end
