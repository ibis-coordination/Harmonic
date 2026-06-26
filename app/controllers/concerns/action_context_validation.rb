# typed: false

# Inner-layer half of the agent context gate: validates declared visibility
# against the action's resolved audience. The outer MCP endpoint catches
# context_missing / identity_* / intention_missing before dispatching.
#
# Scope is MCP-only by design. Agent API tokens default to `mcp_only: true`,
# which `ApplicationController#api_authorize!` enforces — a token in that
# mode hitting a direct REST/markdown action returns 403 before any action
# body runs, so direct-POST writes from agent identities can't bypass the
# context gate. A principal can opt a token out of mcp_only, but that's a
# deliberate choice surfaced on the token creation form, not a default.
module ActionContextValidation
  extend ActiveSupport::Concern

  included do
    append_before_action :validate_action_context!
  end

  private

  def validate_action_context!
    return unless under_mcp_execute_action?
    return unless write_request? # from ActionCapabilityCheck

    # Under representation, `@current_user` is the represented user (a human,
    # not restricted), while the actual API caller is the agent recorded as
    # `@api_token_user`. Gate on the agent so this check fires the same way
    # whether or not rep is active — an agent declaring the wrong visibility
    # tier should be rejected even when acting on someone else's behalf.
    caller = @api_token_user || @current_user
    return if caller.blank?
    return unless CapabilityCheck.restricted_user?(caller)

    audience = Mcp::AudienceResolver.resolve(
      capability_action: determine_capability_action,
      collective: @current_collective.presence
    )

    error = ActionContext.new(Current.mcp_action_context).validate_visibility(audience: audience)
    unless error.nil?
      render json: error.to_response_hash, status: :unprocessable_content
      return
    end

    # Visibility-zone guardrail — sibling to the capability check. Gate on the
    # resolved audience (ground truth), not the declared one: an agent whose
    # owner hasn't granted the `public` zone can't act in the main collective
    # even if it declared the tier correctly. private is always allowed.
    return if CapabilityCheck.zone_allowed?(caller, audience)

    render json: zone_denied_error(audience), status: :forbidden
  end

  def zone_denied_error(zone)
    {
      error: "zone_restricted",
      zone: zone,
      hint: "This agent is not permitted to act in the `#{zone}` visibility zone. " \
            "Its owner can enable that zone in the agent's settings.",
    }
  end

  # `mcp_action_name` is set only by Mcp::EndpointController#call_execute_action,
  # so it precisely identifies "we're inside an MCP execute_action dispatch" —
  # narrower than `harmonic.internal_dispatch`, which also covers automations.
  def under_mcp_execute_action?
    Current.mcp_action_name.present?
  end
end
