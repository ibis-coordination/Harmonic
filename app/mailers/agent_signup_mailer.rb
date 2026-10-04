# typed: false

# Tells a member that an agent has asked to join with them as human principal.
#
# The copy is fixed. Nothing the agent supplied (name, handle) appears in the
# subject or body: the signup endpoint is unauthenticated, so agent-supplied
# text here would let anyone put words in a Harmonic email to a member.
class AgentSignupMailer < ApplicationMailer
  def claim(principal, public_id, tenant)
    @tenant = tenant
    @claim_url = "#{tenant.url}/agent-signups/#{public_id}/claim"
    mail(
      to: principal.email,
      subject: "An agent asked to join #{tenant.domain} with you as their human principal"
    )
  end
end
