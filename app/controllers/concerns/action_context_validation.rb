# typed: false

# Inner-layer half of the agent guardrails. Two checks live here, with
# deliberately different scopes:
#
# 1. Declared-visibility validation — MCP-only. Compares the visibility tier
#    the agent declared in its MCP `context` block against the action's
#    resolved audience. Direct REST/markdown writes carry no context block,
#    so there's nothing to validate; agent tokens also default to the mcp
#    type, which `ApplicationController#api_authorize!` enforces by
#    returning 403 on direct REST/markdown before any action body runs.
#
# 2. Public-write guardrail — fires on EVERY restricted-agent write, MCP or
#    direct REST/markdown, mirroring how the capability check (ActionCapability
#    Check) runs on all writes. The mcp token type fences direct writes for
#    the default token, but a principal can issue a rest-type token instead —
#    a deliberate choice on the token form. Were the gate MCP-only, such a token would reach
#    writes with its restriction silently dropped, the exact bypass the
#    capability layer already closes by running everywhere. So this runs
#    everywhere too: capabilities and the public-write gate are one system with
#    one scope. Only the `public` tier is gated; private and shared are always
#    allowed (see CapabilityCheck.public_writes_allowed?).
module ActionContextValidation
  extend ActiveSupport::Concern

  included do
    append_before_action :validate_action_context!
  end

  private

  def validate_action_context!
    # Mirror ActionCapabilityCheck's two route exemptions exactly — since the
    # public-write gate runs on every write (not just MCP), it must defer on the
    # same routes the capability layer does, or it reintroduces the 403s that
    # layer deliberately avoids.
    #
    # 1. Unknown-action catch-all: let it 404 with the list of real actions
    #    rather than masking that teaching error with a public-write/visibility 403.
    # 2. Session-management writes: whoever starts a representation session can
    #    end it; gating "stop representing" on the represented agent's
    #    permissions would trap the representative in the session.
    return if controller_path == "application" && action_name == "unknown_action_fallback"

    return unless write_request? # from ActionCapabilityCheck

    return if ActionCapabilityCheck::SESSION_MANAGEMENT_WRITES.include?("#{controller_path}##{action_name}")

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

    # Declared-visibility validation is MCP-only: there's no context block to
    # validate on a direct REST/markdown write. The public-write gate below
    # still runs.
    if under_mcp_execute_action?
      error = ActionContext.new(Current.mcp_action_context).validate_visibility(audience: audience)
      unless error.nil?
        render json: error.to_response_hash, status: :unprocessable_content
        return
      end
    end

    # Public-write guardrail — sibling to the capability check, and like it
    # fires on every restricted-agent write regardless of dispatch path (see
    # the module comment). Gate on the resolved audience (ground truth), not
    # the declared one: an agent whose owner hasn't enabled public writes can't
    # act in the main collective even via a direct rest-type token.
    # Only the `public` tier is gated; private and shared are always allowed.
    return unless audience == "public"
    return if CapabilityCheck.public_writes_allowed?(caller)

    render_public_write_denied
  end

  # Under MCP the body is captured and surfaced as the tool-call result, so it
  # must be JSON (Mcp::EndpointController#surface_dispatch_result reads the
  # rendered body). A direct REST/markdown write gets a format-appropriate
  # response, mirroring ActionCapabilityCheck#render_capability_denied.
  def render_public_write_denied
    error = public_write_denied_error
    return render(json: error, status: :forbidden) if under_mcp_execute_action?

    respond_to do |format|
      format.json { render json: error, status: :forbidden }
      format.md   { render plain: "Error: #{error[:hint]}", status: :forbidden }
      format.html { render plain: "Forbidden: #{error[:hint]}", status: :forbidden }
    end
  end

  def public_write_denied_error
    {
      error: "public_writes_disabled",
      zone: "public",
      hint: "This agent is not permitted to write to the public space (the main collective). " \
            "Its owner can enable public writes in the agent's settings.",
    }
  end

  # `mcp_action_name` is set only by Mcp::EndpointController#call_execute_action,
  # so it precisely identifies "we're inside an MCP execute_action dispatch" —
  # narrower than `harmonic.internal_dispatch`, which also covers automations.
  def under_mcp_execute_action?
    Current.mcp_action_name.present?
  end
end
