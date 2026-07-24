# typed: false

# Human-facing harmonic-bridge setup UI. All bridge-setup actions live
# here so the resource owns its own action surface, same shape as
# AgentAutomationsController.
#
# Routes:
#   GET  /ai-agents/:handle/bridge-setup                       new (landing + Connect button)
#   GET  /ai-agents/:handle/bridge-setup/actions               actions_index_new
#   GET  /ai-agents/:handle/bridge-setup/actions/connect_…     describe_connect_harmonic_bridge
#   POST /ai-agents/:handle/bridge-setup/actions/connect_…     execute_connect_harmonic_bridge
#   GET  /ai-agents/:handle/bridge-setup/:public_id            show
#   GET  /ai-agents/:handle/bridge-setup/:public_id/actions    actions_index_show
#   GET  /ai-agents/:handle/bridge-setup/:public_id/actions/cancel_…   describe_cancel_harmonic_bridge_setup
#   POST /ai-agents/:handle/bridge-setup/:public_id/actions/cancel_…   execute_cancel_harmonic_bridge_setup
class AiAgentBridgeSetupsController < ApplicationController
  def current_resource_model
    HarmonicBridgeSetup
  end

  before_action :require_login
  before_action :set_ai_agent
  before_action :authorize_parent
  before_action :load_setup, only: [
    :show, :actions_index_show,
    :describe_cancel_harmonic_bridge_setup, :execute_cancel_harmonic_bridge_setup,
  ]

  # GET /ai-agents/:handle/bridge-setup/:public_id
  def show
    @page_title = "harmonic-bridge setup — #{@ai_agent.display_name}"
    @public_setup_url = harmonic_bridge_setup_url(public_id: @setup.public_id)
    @bridge_add_command = "harmonic-bridge add --from #{@public_setup_url}"
    # Each agent gets its own sprite — its own environment/workspace — so the
    # command names the sprite after the agent. Lowercased and hyphenated:
    # sprite names become DNS subdomains (<name>-<suffix>.sprites.app).
    sprite_name = "harmonic-#{params[:handle]}".downcase.gsub(/[^a-z0-9-]+/, "-")
    @sprite_setup_command =
      "npx @ibis-coordination/harmonic-bridge setup-sprite --from #{@public_setup_url} --sprite-name #{sprite_name} --harness claude-code"
  end

  # GET /ai-agents/:handle/bridge-setup
  def new
    @page_title = "Connect harmonic-bridge — #{@ai_agent.display_name}"
    # Pre-flight: when a webhook already exists, render a "remove your
    # existing webhook first" state instead of letting the user submit and
    # bounce off HarmonicBridgeSetup's no_existing_notification_webhook_for_agent
    # validation. The model validation is still the real guard.
    @notification_webhook = AutomationRule.tenant_scoped_only.notification_webhook_for(@ai_agent).first
  end

  # GET /ai-agents/:handle/bridge-setup/actions
  def actions_index_new
    @page_title = "Actions | Connect harmonic-bridge"
    render_actions_index(ActionsHelper.actions_for_route("/ai-agents/:handle/bridge-setup"))
  end

  # GET /ai-agents/:handle/bridge-setup/:public_id/actions
  def actions_index_show
    @page_title = "Actions | harmonic-bridge setup"
    render_actions_index(ActionsHelper.actions_for_route("/ai-agents/:handle/bridge-setup/:public_id"))
  end

  # GET /ai-agents/:handle/bridge-setup/actions/connect_harmonic_bridge
  def describe_connect_harmonic_bridge
    render_action_description(ActionsHelper.action_description("connect_harmonic_bridge", resource: @ai_agent))
  end

  # POST /ai-agents/:handle/bridge-setup/actions/connect_harmonic_bridge
  # Mints a HarmonicBridgeSetup for this agent. Reuses any pending
  # (unredeemed, unexpired) setup so a double-click — or two LLM turns
  # racing — can't litter the DB. Capability-restricted users are blocked
  # by ActionCapabilityCheck before reaching here
  # (connect_harmonic_bridge is in AI_AGENT_ALWAYS_BLOCKED).
  def execute_connect_harmonic_bridge
    setup = pending_setup_for(@ai_agent) || HarmonicBridgeSetup.create(
      tenant: current_tenant,
      ai_agent_user: @ai_agent,
      created_by_user: @current_user
    )
    if setup.errors.any?
      return render_action_error({
        action_name: "connect_harmonic_bridge",
        resource: @ai_agent,
        error: setup.errors.full_messages.to_sentence,
      })
    end

    render_action_success({
      action_name: "connect_harmonic_bridge",
      resource: @ai_agent,
      result: "Bridge setup URL minted. Paste the command on your bridge host.",
      redirect_to: ai_agent_bridge_setup_path(@ai_agent.handle, setup.public_id),
    })
  end

  # GET /ai-agents/:handle/bridge-setup/:public_id/actions/cancel_harmonic_bridge_setup
  def describe_cancel_harmonic_bridge_setup
    render_action_description(ActionsHelper.action_description("cancel_harmonic_bridge_setup", resource: @setup))
  end

  # POST /ai-agents/:handle/bridge-setup/:public_id/actions/cancel_harmonic_bridge_setup
  def execute_cancel_harmonic_bridge_setup
    # If the bridge already redeemed (rule + token minted) but hasn't
    # finalized verification, revert clears the orphaned rule + token.
    # Finalized webhooks must be removed from the webhook page proper —
    # cancelling here would silently delete an active subscription.
    @setup.revert_completion! if @setup.redeemed_at.present? && @setup.webhook_registered_at.nil?
    @setup.destroy!

    render_action_success({
      action_name: "cancel_harmonic_bridge_setup",
      resource: @setup,
      result: "Bridge setup cancelled.",
      redirect_to: ai_agent_settings_path(@ai_agent.handle),
    })
  end

  private

  def require_login
    return if @current_user

    redirect_to "/login"
  end

  def set_ai_agent
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render(status: :not_found, plain: "404 Not Found") if tu.nil?

    @ai_agent = tu.user
    render(status: :not_found, plain: "404 Not Found") unless @ai_agent.external_ai_agent?
  end

  def authorize_parent
    return if @ai_agent.parent_id == @current_user&.id

    redirect_to "/", alert: "You don't have permission to manage this agent's webhook."
  end

  def load_setup
    return if @ai_agent.nil? # earlier before_action already 404'd

    @setup = HarmonicBridgeSetup.tenant_scoped_only
      .where(ai_agent_user_id: @ai_agent.id)
      .find_by(public_id: params[:public_id])
    render(status: :not_found, plain: "404 Not Found") if @setup.nil?
  end

  # An existing redeemable (unredeemed + unexpired) setup for this agent.
  def pending_setup_for(agent)
    HarmonicBridgeSetup.tenant_scoped_only
      .where(ai_agent_user_id: agent.id, redeemed_at: nil)
      .where("expires_at > ?", Time.current)
      .order(created_at: :desc)
      .first
  end
end
