# typed: true
# frozen_string_literal: true

# Two-phase account closure. close! locks the account reversibly: sessions,
# refresh tokens, push subscriptions, and API tokens are revoked, automation
# rules are disabled, plan billing stops — but login identities, PII, content,
# and the prepaid balance survive. restore! undoes the lock during the grace
# window. Once the window expires, AccountClosureScrubJob runs the
# irreversible scrub (DataDeletionManager#delete_user!).
class AccountClosureService
  extend T::Sig

  GRACE_PERIOD = 30.days

  # Collectives that block closure: the user is their only active admin while
  # other active members remain. Lookups are pinned to each membership's
  # tenant, so the check is correct under any thread scope. Shared by close!
  # and the scrub's own precheck.
  sig { params(user: User).returns(T::Array[String]) }
  def self.sole_admin_blocking_handles(user)
    CollectiveMember.for_user_across_tenants(user).where(archived_at: nil).filter_map do |cm|
      next unless cm.is_admin?

      collective = Collective.tenant_scoped_only(cm.tenant_id).find_by(id: cm.collective_id)
      next if collective.nil? || collective.archived_at.present?

      active_members = CollectiveMember.tenant_scoped_only(cm.tenant_id)
        .where(collective_id: collective.id, archived_at: nil)
      next unless T.unsafe(active_members).where_has_role("admin").count == 1
      next unless active_members.where.not(user_id: user.id).exists?

      collective.handle
    end
  end

  sig { params(user: User).void }
  def self.close!(user:)
    raise "Only human accounts can be closed" unless user.human?
    raise "Account has already been permanently deleted" if user.scrubbed_at.present?
    raise "Account is already closing" if user.closing?

    blocking = sole_admin_blocking_handles(user)
    if blocking.any?
      raise "Cannot close account: they are the sole admin of collectives with other members: " \
            "#{blocking.join(', ')}. Transfer the admin role first (update_member_roles)."
    end

    # Billing first, before any local state change: if the Stripe call fails,
    # closing aborts cleanly. The customer object and prepaid balance survive
    # until the scrub, so a restored account keeps its balance.
    stripe_customer = StripeCustomer.find_by(billable: user)
    if stripe_customer&.active && stripe_customer.stripe_subscription_id.present?
      StripeService.cancel_subscription!(stripe_customer)
    end

    now = Time.current
    ActiveRecord::Base.transaction do
      user.update!(close_requested_at: now)
      TenantUser.for_user_across_tenants(user).update_all(close_requested_at: now)
      disable_rules!(user, at: now)
      User.where(parent_id: user.id).find_each do |ai_agent| # User has no tenant scope
        TenantUser.for_user_across_tenants(ai_agent).update_all(close_requested_at: now)
        disable_rules!(ai_agent, at: now)
      end
      # Sessions, refresh tokens, push subscriptions, and API tokens die now.
      # Token revocation is not reversible — a restored user issues new tokens.
      user.revoke_all_sessions!
    end
  end

  sig { params(user: User).void }
  def self.restore!(user:)
    raise "Account has already been permanently deleted" if user.scrubbed_at.present?
    raise "Account is not closing" unless user.closing?

    close_time = T.must(user.close_requested_at)
    ActiveRecord::Base.transaction do
      # Only the closure machinery touches this user's rules during the grace
      # window (the user cannot log in), so rows disabled at or after close
      # time are exactly the rows close! disabled.
      reenable_rules!(user, since: close_time)
      User.where(parent_id: user.id).find_each do |ai_agent|
        reenable_rules!(ai_agent, since: close_time)
        TenantUser.for_user_across_tenants(ai_agent).update_all(close_requested_at: nil)
      end
      TenantUser.for_user_across_tenants(user).update_all(close_requested_at: nil)
      user.update!(close_requested_at: nil)
    end
  end

  # Accounts whose grace window has expired and whose scrub has not run yet.
  sig { returns(T.untyped) }
  def self.scrub_due
    User.where(close_requested_at: ..GRACE_PERIOD.ago, scrubbed_at: nil)
  end

  sig { params(owner: User, at: ActiveSupport::TimeWithZone).void }
  private_class_method def self.disable_rules!(owner, at:)
    AutomationRule.for_user_across_tenants(owner)
      .where(deleted_at: nil, enabled: true)
      .update_all(enabled: false, updated_at: at)
  end

  sig { params(owner: User, since: ActiveSupport::TimeWithZone).void }
  private_class_method def self.reenable_rules!(owner, since:)
    AutomationRule.for_user_across_tenants(owner)
      .where(deleted_at: nil, enabled: false)
      .where(updated_at: since..)
      .update_all(enabled: true, updated_at: Time.current)
  end
end
