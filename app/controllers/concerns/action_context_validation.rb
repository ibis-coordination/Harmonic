# typed: false

# Inner-layer half of the agent context gate: validates declared visibility
# against the action's resolved audience. The outer MCP endpoint catches
# context_missing / identity_* / intention_missing before dispatching.
module ActionContextValidation
  extend ActiveSupport::Concern

  included do
    append_before_action :validate_action_context!
  end

  private

  def validate_action_context!
    return unless under_mcp_execute_action?
    return unless write_request? # from ActionCapabilityCheck
    return if @current_user.blank?
    return unless CapabilityCheck.restricted_user?(@current_user)

    audience = Mcp::AudienceResolver.resolve(
      capability_action: determine_capability_action,
      collective: @current_collective.presence
    )

    error = ActionContext.new(Current.mcp_action_context).validate_visibility(audience: audience)
    return if error.nil?

    render json: error.to_response_hash, status: :unprocessable_content
  end

  # `mcp_action_name` is set only by Mcp::EndpointController#call_execute_action,
  # so it precisely identifies "we're inside an MCP execute_action dispatch" —
  # narrower than `harmonic.internal_dispatch`, which also covers automations.
  def under_mcp_execute_action?
    Current.mcp_action_name.present?
  end
end
