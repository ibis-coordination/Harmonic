# typed: true

class AiAgentConnectController < ApplicationController
  extend T::Sig

  before_action :require_signed_in_human

  def create
    @ai_agent = find_ai_agent_by_handle
    return render status: :not_found, plain: "404 not found" if @ai_agent.nil?

    settings_path = "/ai-agents/#{@ai_agent.handle}/settings"

    # Block archived agents (mirrors the guard in AiAgentsController#update_settings).
    if @ai_agent.archived?
      flash[:alert] = "Cannot connect a deactivated agent. Reactivate it on the billing page first."
      return redirect_to settings_path
    end

    # Block agents that haven't completed billing setup — otherwise a parent
    # could create an unbilled agent and mint a free token here. Mirrors the
    # guard in ApiTokensController#create.
    if @ai_agent.pending_billing_setup?
      flash[:alert] = "This agent is pending billing setup. Complete billing first to connect a client."
      return redirect_to billing_show_path
    end

    @harness_key = params[:harness]
    @harness_name = Mcp::Connect.display_name(@harness_key)
    if @harness_name.nil?
      return render status: :unprocessable_entity, plain: "Unknown harness"
    end

    @token = @ai_agent.api_tokens.new(
      tenant: current_tenant,
      name: "#{@harness_name} connection",
      client_name: @harness_name,
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
      mcp_only: true,
    )

    begin
      @token.save!
    rescue ActiveRecord::RecordInvalid => e
      flash[:alert] = e.record.errors.full_messages.to_sentence.presence || "Could not create token."
      return redirect_to settings_path
    end

    render "show"
  end

  private

  sig { void }
  def require_signed_in_human
    if current_user.nil?
      redirect_to "/login"
    elsif !current_user.human?
      render status: :forbidden, plain: "403 Forbidden"
    end
  end

  sig { returns(T.nilable(User)) }
  def find_ai_agent_by_handle
    current_user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant.id, handle: params[:handle] })
      .first
  end
end
