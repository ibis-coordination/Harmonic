# typed: true

# TrusteeActionValidator - Validates that a trustee user has the required capability
# to perform an action within a specific studio context.
#
# This is a stub that will be fully implemented in Phase 4 of the TrusteeGrants plan.
# Currently, it always returns false for trustee grant trustees (not implemented).
#
# Usage:
#   validator = TrusteeActionValidator.new(trustee_user, superagent: current_studio)
#   if validator.can_perform?("create_note")
#     # Allow the action
#   else
#     # Deny the action
#   end
#
class TrusteeActionValidator
  extend T::Sig

  # Maps action names to capability names
  CAPABILITY_MAP = T.let({
    "create_note" => "create_notes",
    "create_decision" => "create_decisions",
    "create_commitment" => "create_commitments",
    "vote" => "vote",
    "commit" => "commit",
    "create_comment" => "comment",
    "pin" => "pin",
    "unpin" => "pin",
  }.freeze, T::Hash[String, String])

  sig { params(user: User, superagent: Superagent).void }
  def initialize(user, superagent:)
    @user = user
    @superagent = superagent
  end

  # Check if the user can perform the specified action
  # Returns true if:
  # - User is not a trustee (normal users can do anything)
  # - User is a superagent trustee (studio trustees have full access in their studio)
  # - User is a delegation trustee with active permission that includes the capability
  sig { params(action_name: String).returns(T::Boolean) }
  def can_perform?(action_name)
    # Non-trustee users are not subject to capability checks here
    # (they have their own authorization via studio membership)
    return true unless @user.trustee?

    # Superagent trustees have full access to their studio
    return true if @user.superagent_trustee?

    # For trustee grant trustees, check the grant
    grant = TrusteeGrant.find_by(trustee_user: @user)
    return false unless grant&.active?
    return false unless grant.allows_studio?(@superagent)

    # Find the required capability for this action
    required_capability = CAPABILITY_MAP[action_name]

    # If no capability mapping exists, allow the action (read/navigate)
    return true unless required_capability

    # Check if the grant includes this capability
    grant.has_capability?(required_capability)
  end
end
