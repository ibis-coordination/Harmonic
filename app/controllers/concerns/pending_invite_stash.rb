# typed: false

# Owns the session-stashed "pending invite" — an invite the user arrived
# with but has not yet explicitly accepted on the confirmation page.
#
# The session cookie is shared across all tenant subdomains (see
# config/initializers/session_store.rb), so the stash is keyed per tenant:
# tenant A's in-flight invite must survive visits to tenant B (a B-scoped
# lookup can't tell a foreign code from a dead one), and concurrent invite
# flows on two tenants must not clobber each other. All reads, writes, and
# clears go through these helpers — controllers never touch the session key
# directly.
module PendingInviteStash
  extend ActiveSupport::Concern

  SESSION_KEY = "pending_invite_codes".freeze

  private

  def stash_pending_invite!(invite)
    codes = session[SESSION_KEY] || {}
    codes[invite.tenant_id] = invite.code
    session[SESSION_KEY] = codes
  end

  def pending_invite_code(tenant = @current_tenant)
    (session[SESSION_KEY] || {})[tenant.id]
  end

  # Resolves the stashed code for the tenant to an invite the user can still
  # accept. A stashed code that no longer resolves (expired, revoked) is
  # dropped so it stops short-circuiting the signup pages — deleting here is
  # safe because the lookup ran in the tenant that owns the stash entry.
  def resolve_pending_invite(tenant: @current_tenant, user: @current_user)
    code = pending_invite_code(tenant)
    return nil if code.blank?

    invite = Invite.tenant_scoped_only(tenant.id).find_by(code: code)
    return invite if invite&.is_acceptable_by_user?(user)

    clear_pending_invite!(tenant)
    nil
  end

  def clear_pending_invite!(tenant = @current_tenant)
    codes = session[SESSION_KEY]
    return if codes.blank?

    codes.delete(tenant.id)
    if codes.empty?
      session.delete(SESSION_KEY)
    else
      session[SESSION_KEY] = codes
    end
  end
end
