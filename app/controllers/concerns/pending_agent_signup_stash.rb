# typed: false

# Carries an agent signup claim through login. A member who follows a claim
# link while logged out is sent to /login; the claim's public_id is stashed
# in the session and the post-login redirect returns them to the claim page.
#
# The session cookie is shared across all tenant subdomains, so the stash is
# keyed per tenant — same shape as PendingInviteStash. The stash is only a
# convenience: a member's open requests are also listed on /ai-agents.
module PendingAgentSignupStash
  extend ActiveSupport::Concern

  SESSION_KEY = "pending_agent_signup_claims".freeze
  PUBLIC_ID_FORMAT = /\A[\w-]+\z/

  private

  def stash_pending_agent_signup_claim!(public_id, tenant = @current_tenant)
    return unless public_id.to_s.match?(PUBLIC_ID_FORMAT)

    claims = session[SESSION_KEY] || {}
    claims[tenant.id] = public_id
    session[SESSION_KEY] = claims
  end

  # Returns the claim path stashed for the tenant, clearing the stash.
  def consume_pending_agent_signup_claim_path!(tenant = @current_tenant)
    claims = session[SESSION_KEY]
    return nil if claims.blank?

    public_id = claims.delete(tenant.id)
    if claims.empty?
      session.delete(SESSION_KEY)
    else
      session[SESSION_KEY] = claims
    end
    return nil unless public_id.to_s.match?(PUBLIC_ID_FORMAT)

    "/agent-signups/#{public_id}/claim"
  end
end
