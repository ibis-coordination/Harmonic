# typed: false

# Tells the holder of an email address that an agent has asked to join with
# them as human principal. The address may belong to a member, to a user of
# another tenant, or to nobody yet; the copy is the same for all three.
#
# The copy is fixed. Nothing the agent supplied (name, handle) appears in the
# subject or body: the signup endpoint is unauthenticated, so agent-supplied
# text here would let anyone put words in a Harmonic email to anyone.
class AgentSignupMailer < ApplicationMailer
  def claim(email, public_id, tenant)
    @tenant = tenant
    @claim_url = "#{tenant.url}/agent-signups/#{public_id}/claim"
    mail(
      to: email,
      subject: "An agent asked to join #{tenant.domain} with you as their human principal"
    )
  end
end
