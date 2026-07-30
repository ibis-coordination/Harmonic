# typed: true
# frozen_string_literal: true

# Two-phase account deletion. request_deletion! locks the account reversibly:
# sessions, refresh tokens, push subscriptions, and API tokens are revoked,
# automation rules are disabled, plan billing stops — but login identities,
# PII, content, and the prepaid balance survive. restore! undoes the lock
# during the grace period. Once the period expires, AccountDeletionScrubJob
# runs the irreversible scrub (DataDeletionManager#delete_user!).
class AccountDeletionService
  extend T::Sig

  GRACE_PERIOD = 30.days

  # Collectives that block deletion: the user is their only active admin while
  # other active members remain. Lookups are pinned to each membership's
  # tenant, so the check is correct under any thread scope. Shared by request_deletion!
  # and the scrub's own precheck. Pass tenant_id to scope the check to one
  # subdomain (per-subdomain deletion only cares about that tenant's collectives).
  sig { params(user: User, tenant_id: T.nilable(String)).returns(T::Array[String]) }
  def self.sole_admin_blocking_handles(user, tenant_id: nil)
    memberships = CollectiveMember.for_user_across_tenants(user).where(archived_at: nil)
    memberships = memberships.where(tenant_id: tenant_id) if tenant_id
    memberships.filter_map do |cm|
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
  def self.request_deletion!(user:)
    raise "Only human accounts can be deleted this way" unless user.human?
    raise "Account has already been permanently deleted" if user.scrubbed_at.present?
    raise "Account deletion is already requested" if user.pending_deletion?

    blocking = sole_admin_blocking_handles(user)
    if blocking.any?
      raise "Cannot delete account: they are the sole admin of collectives with other members: " \
            "#{blocking.join(", ")}. Transfer the admin role first (update_member_roles)."
    end

    # Billing first, before any local state change: if the Stripe call fails,
    # the request aborts cleanly. The customer object and prepaid balance survive
    # until the scrub, so a restored account keeps its balance.
    stripe_customer = StripeCustomer.find_by(billable: user)
    StripeService.cancel_subscription!(stripe_customer) if stripe_customer&.active && stripe_customer.stripe_subscription_id.present?

    now = Time.current
    ActiveRecord::Base.transaction do
      user.update!(deletion_requested_at: now)
      TenantUser.for_user_across_tenants(user).update_all(deletion_requested_at: now)
      disable_rules!(user, at: now)
      User.where(parent_id: user.id).find_each do |ai_agent| # User has no tenant scope
        TenantUser.for_user_across_tenants(ai_agent).update_all(deletion_requested_at: now)
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
    raise "Account is not pending deletion" unless user.pending_deletion?

    request_time = T.must(user.deletion_requested_at)
    ActiveRecord::Base.transaction do
      # Only the deletion machinery touches this user's rules during the grace
      # period (the user cannot log in), so rows disabled at or after the
      # request time are exactly the rows request_deletion! disabled.
      reenable_rules!(user, since: request_time)
      User.where(parent_id: user.id).find_each do |ai_agent|
        reenable_rules!(ai_agent, since: request_time)
        TenantUser.for_user_across_tenants(ai_agent).update_all(deletion_requested_at: nil)
      end
      TenantUser.for_user_across_tenants(user).update_all(deletion_requested_at: nil)
      user.update!(deletion_requested_at: nil)
    end
  end

  # Per-subdomain deletion: locks the user's account on ONE tenant while the
  # rest of their account keeps working. The shared session survives (lockout
  # on the deleted subdomain comes from the controller gate, which keys off
  # TenantUser#deletion_requested_at); only that tenant's API tokens, rules,
  # and agent presences stop. Billing is global and is untouched.
  sig { params(user: User, tenant: Tenant).void }
  def self.request_tenant_deletion!(user:, tenant:)
    raise "Only human accounts can be deleted this way" unless user.human?
    raise "Account has already been permanently deleted" if user.scrubbed_at.present?
    raise "Account deletion is already requested for the whole account" if user.pending_deletion?

    tenant_user = TenantUser.tenant_scoped_only(tenant.id).find_by(user_id: user.id)
    raise "No account on this subdomain" if tenant_user.nil?
    raise "Account has already been permanently deleted on this subdomain" if tenant_user.scrubbed_at.present?
    raise "Account deletion is already requested on this subdomain" if tenant_user.deletion_requested_at.present?

    other_active = TenantUser.for_user_across_tenants(user)
      .where(archived_at: nil, scrubbed_at: nil)
      .where.not(id: tenant_user.id)
    raise "This is the user's only subdomain account — use global account deletion" unless other_active.exists?

    blocking = sole_admin_blocking_handles(user, tenant_id: tenant.id)
    if blocking.any?
      raise "Cannot delete account on this subdomain: they are the sole admin of collectives " \
            "with other members: #{blocking.join(", ")}. Transfer the admin role first (update_member_roles)."
    end

    now = Time.current
    ActiveRecord::Base.transaction do
      tenant_user.update!(deletion_requested_at: now)
      disable_rules!(user, at: now, tenant_id: tenant.id)
      revoke_tenant_tokens!(user, tenant_id: tenant.id)
      User.where(parent_id: user.id).find_each do |ai_agent| # User has no tenant scope
        TenantUser.tenant_scoped_only(tenant.id).where(user_id: ai_agent.id)
          .update_all(deletion_requested_at: now)
        disable_rules!(ai_agent, at: now, tenant_id: tenant.id)
        revoke_tenant_tokens!(ai_agent, tenant_id: tenant.id)
      end
    end
  end

  sig { params(user: User, tenant: Tenant).void }
  def self.restore_tenant!(user:, tenant:)
    raise "Account has already been permanently deleted" if user.scrubbed_at.present?
    raise "Account deletion was requested for the whole account — restore the whole account instead" if user.pending_deletion?

    tenant_user = TenantUser.tenant_scoped_only(tenant.id).find_by(user_id: user.id)
    raise "No account on this subdomain" if tenant_user.nil?
    raise "Account has already been permanently deleted on this subdomain" if tenant_user.scrubbed_at.present?
    raise "Account is not pending deletion on this subdomain" if tenant_user.deletion_requested_at.nil?

    request_time = T.must(tenant_user.deletion_requested_at)
    ActiveRecord::Base.transaction do
      reenable_rules!(user, since: request_time, tenant_id: tenant.id)
      User.where(parent_id: user.id).find_each do |ai_agent|
        reenable_rules!(ai_agent, since: request_time, tenant_id: tenant.id)
        TenantUser.tenant_scoped_only(tenant.id).where(user_id: ai_agent.id)
          .update_all(deletion_requested_at: nil)
      end
      tenant_user.update!(deletion_requested_at: nil)
    end
  end

  # Accounts whose grace window has expired and whose scrub has not run yet.
  # (The per-subdomain counterpart lives on AccountDeletionScrubJob — TenantUser
  # is tenant-scoped, and system-job-wide queries belong in jobs.)
  sig { returns(T.untyped) }
  def self.scrub_due
    User.where(deletion_requested_at: ..GRACE_PERIOD.ago, scrubbed_at: nil)
  end

  sig { params(owner: User, at: ActiveSupport::TimeWithZone, tenant_id: T.nilable(String)).void }
  private_class_method def self.disable_rules!(owner, at:, tenant_id: nil)
    rules = AutomationRule.for_user_across_tenants(owner)
      .where(deleted_at: nil, enabled: true)
    rules = rules.where(tenant_id: tenant_id) if tenant_id
    rules.update_all(enabled: false, updated_at: at)
  end

  sig { params(owner: User, since: ActiveSupport::TimeWithZone, tenant_id: T.nilable(String)).void }
  private_class_method def self.reenable_rules!(owner, since:, tenant_id: nil)
    rules = AutomationRule.for_user_across_tenants(owner)
      .where(deleted_at: nil, enabled: false)
      .where(updated_at: since..)
    rules = rules.where(tenant_id: tenant_id) if tenant_id
    rules.update_all(enabled: true, updated_at: Time.current)
  end

  # One tenant's API tokens only — the per-subdomain counterpart of the token
  # revocation inside revoke_all_sessions!.
  sig { params(owner: User, tenant_id: String).void }
  private_class_method def self.revoke_tenant_tokens!(owner, tenant_id:)
    ApiToken.for_user_across_tenants(owner)
      .where(tenant_id: tenant_id, deleted_at: nil)
      .find_each(&:delete!)
  end
end
