# typed: false

# ActionAuthorizationCheck enforces the `authorization:` rule declared on each
# ACTION_DEFINITIONS entry at execute time — not just when building markdown
# action listings.
#
# Before this concern existed, `authorization:` was consulted only by listing
# helpers (which actions an /actions page shows to which users). Execution was
# gated solely by whatever `before_action :authorize_*` a controller happened to
# declare. An action with a tight `authorization:` rule but a thin controller
# shipped an unguarded endpoint that looked gated to anyone reading the action
# definition. This concern closes that gap: every POST to `/actions/<name>` now
# runs `ActionAuthorization.authorized?` before the controller's execute method.
#
# This runs as an `append_before_action` and is included in ApplicationController
# AFTER ActionCapabilityCheck and ActionContextValidation, so those layers
# short-circuit first (a capability/public-write denial shouldn't get an
# authorization chaser, and vice versa).
#
# The gate is ADDITIVE: existing controller `authorize_*` before_actions still
# run (and run first, since they are regular before_actions rather than appended
# ones). This concern can only ADD 403s where a rule denies a user the controller
# would have let through — it never weakens an existing guard.
#
# @see ActionAuthorization for the rule evaluation
# @see ActionsHelper::ACTION_DEFINITIONS for the per-action `authorization:` rules
# @see MarkdownHelper#build_authorization_context for the listing-side context
module ActionAuthorizationCheck
  extend ActiveSupport::Concern

  # Actions that end a representation session. Whoever holds the session can end
  # it, regardless of the represented user's grant permissions — mirroring
  # ActionCapabilityCheck::SESSION_MANAGEMENT_WRITES. Running the authorization
  # gate on these would let a grant that omits `end_representation` from its
  # action-permission list trap the representative in a session they can't leave.
  SESSION_MANAGEMENT_ACTIONS = Set.new(["end_representation"]).freeze

  included do
    append_before_action :check_action_authorization
  end

  private

  def check_action_authorization
    # Only /actions/<name> POST dispatches are gated here. Legacy HTML and REST
    # routes carry no action name in the path; they keep their controller guards
    # plus the capability layer (ActionCapabilityCheck::CONTROLLER_ACTION_MAP).
    return unless request.post? && request.path.match?(%r{/actions/[^/]+/?$})
    return unless defined?(@current_user) && @current_user.present?

    # Defer to the unknown-action catch-all (404 + the list of real actions at
    # this path) rather than masking that teaching error with a 403 — mirroring
    # ActionCapabilityCheck and ActionContextValidation.
    return if controller_path == "application" && action_name == "unknown_action_fallback"

    action_name = extract_action_name_from_path
    return if action_name.blank?
    return if SESSION_MANAGEMENT_ACTIONS.include?(action_name)

    rule = ActionsHelper::ACTION_DEFINITIONS.dig(action_name, :authorization)
    # Actions with no declared rule fall through to the controller's own guards.
    return if rule.nil?

    return if ActionAuthorization.authorized?(action_name, @current_user, authorization_context)

    render_authorization_denied(action_name)
  end

  # Context passed to ActionAuthorization.authorized? at execute time.
  #
  # `resource` uses `current_resource` rather than the `@note` / `@decision` /
  # `@commitment` instance variables: this before_action is appended in
  # ApplicationController and therefore runs BEFORE a subclass's own
  # resource-loading before_action (e.g. `set_list`), so those ivars are not yet
  # set at gate time. `current_resource` is memoized and resolves from params via
  # `current_resource_model`, so it works regardless of before_action order.
  #
  # `current_resource` only covers the commentable/pinnable resource family
  # (Note/Decision/Commitment). Controllers whose resource is outside that family
  # (e.g. UserList, which intentionally stays out of `current_resource`) override
  # this method to supply the resource for authorization only.
  #
  # `represented_user` is whoever the caller can represent (representative
  # checks); `target_user` is the user the action is about (self checks).
  def authorization_context
    {
      collective: @current_collective,
      resource: current_resource,
      target_user: @showing_user || @target_user,
      represented_user: @ai_agent || @target_agent || @grant&.target,
      representation_session: @current_representation_session,
    }
  end

  # Mirrors ActionCapabilityCheck#render_capability_denied and
  # ActionContextValidation#render_public_write_denied: JSON body when dispatched
  # under MCP (surface_dispatch_result reads the rendered body), otherwise a
  # format-appropriate 403.
  def render_authorization_denied(action_name)
    error_message = "You are not authorized to perform '#{action_name}'"

    if Current.mcp_action_name.present?
      render json: { error: error_message }, status: :forbidden
      return
    end

    respond_to do |format|
      format.md { render plain: "Error: #{error_message}", status: :forbidden }
      format.html { render plain: "Forbidden: #{error_message}", status: :forbidden }
      format.json { render json: { error: error_message }, status: :forbidden }
    end
  end
end
