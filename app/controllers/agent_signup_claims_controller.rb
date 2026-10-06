# typed: false

# The human principal's side of agent signup: the page where the person an
# agent named reviews the request and accepts or declines it. See AgentSignup
# for the lifecycle and AgentSignupsController for the agent's side.
#
#   GET  /agent-signups/:public_id/claim    → the claim page (HTML form; the
#                                             markdown view shows the request
#                                             and points to the browser)
#   POST /agent-signups/:public_id/claim    → accept: creates the agent
#   POST /agent-signups/:public_id/decline  → decline
#
# Only the holder of the email the signup names can claim: a human whose
# verified email matches. Everyone else sees the same "not addressed to you"
# page, so the page reveals nothing about who was named.
#
# The addressee need not be a member yet. The claim link is the one
# destination; the app's gates are detours that return to it: the login wall
# (the claim path is stashed in the session and consumed after login, or
# after accepting an invite), the membership gate (open tenants add the
# user; invite-only tenants send them to /invite-required, where the invite
# the signup carries is waiting), and the activation gate (/activate returns
# here). Two guards below cover what the gates leave to the controller.
#
# Accepting mints a token later (at the agent's pickup), so the page sits
# behind the same "api_tokens" reverification as agent creation.
class AgentSignupClaimsController < ApplicationController
  include RequiresReverification
  include PendingAgentSignupStash

  # Runs ahead of ApplicationController's login and membership gates, which
  # would redirect before the claim could be stashed.
  prepend_before_action :stash_claim_for_return

  # First, so the pages the guards below render carry the title too.
  before_action :set_page_chrome
  before_action :require_agent_signup_enabled
  before_action :require_browser_for_claim, only: [:accept, :decline]
  before_action :require_login_for_claim
  before_action :require_membership_for_claim
  before_action :require_verified_email_for_claim
  before_action -> { require_reverification(scope: "api_tokens") }
  before_action :load_signup
  before_action :require_addressee

  def show
    return render_unavailable unless @signup.claimable_by?(current_user)

    render_claim_form
  end

  def accept
    return render_unavailable(:not_addressed) unless AgentSignup.eligible_principal?(current_user, tenant: current_tenant)

    if params[:name].to_s.strip.blank?
      flash.now[:alert] = "Enter a name for the agent."
      return render_claim_form(status: :unprocessable_entity)
    end
    unless ActiveModel::Type::Boolean.new.cast(params[:confirm_responsibility]) == true
      flash.now[:alert] = "You must confirm that you take responsibility for this agent."
      return render_claim_form(status: :unprocessable_entity)
    end

    outcome, result = accept_under_lock
    SecurityAuditLog.log_agent_signup_pairing_lockout(signup: @signup, ip: request.remote_ip) if outcome == :wrong_code && @signup.expired?

    case outcome
    when :unavailable
      render_unavailable
    when :wrong_code
      return render_unavailable if @signup.expired?

      # Shown at the field, not in the flash: the form is long and the field
      # is at the bottom, where the principal just was.
      @pairing_error = "That pairing code does not match. Check the code the agent gave you."
      render_claim_form(status: :unprocessable_entity)
    when :billing_setup_required
      session[:billing_return_to] = claim_path
      flash[:notice] = "Set up billing to claim this agent"
      redirect_to "/billing"
    when :billing_confirmation_required
      flash.now[:alert] = "You must confirm the billing charge to claim this agent."
      render_claim_form(status: :unprocessable_entity)
    when :handle_taken
      flash.now[:alert] = "That handle is already taken. Please choose a different one."
      render_claim_form(status: :unprocessable_entity)
    when :created
      finish_claim(result.ai_agent)
    end
  end

  def decline
    @signup.decline!(by: current_user)
    SecurityAuditLog.log_agent_signup_declined(signup: @signup, ip: request.remote_ip)
    flash[:notice] = "Request declined. No agent was created."
    redirect_to ai_agents_path
  rescue AgentSignup::NotClaimable
    render_unavailable
  end

  private

  def require_agent_signup_enabled
    return if current_tenant&.agent_signup_enabled?

    render status: :not_found, plain: "404 not found"
  end

  # Accepting an agent is an explicit, interactive step for a human, the same
  # stance invite acceptance takes. The markdown claim page shows the request
  # and points to the browser.
  def require_browser_for_claim
    return if request.format.html?

    render status: :not_acceptable,
           plain: "Claiming or declining an agent is an interactive step. Open /agent-signups/#{params[:public_id]}/claim in a browser."
  end

  # For a visitor who is logged out, not a member yet, or not activated yet:
  # stash the claim path so login, registration, invite acceptance or the
  # activation checklist can come back to it, and the invite the signup
  # carries so /invite-required finds it. (The activation gate's own return
  # path does not survive an emailed confirmation link; the stash does.)
  def stash_claim_for_return
    tenant = Tenant.find_by(subdomain: request.subdomain)
    return if tenant.nil?

    user = User.find_by(id: session[:user_id]) if session[:user_id].present?
    return if user&.fully_activated_for?(tenant)

    stash_pending_agent_signup_claim!(params[:public_id], tenant)
    invite = AgentSignup.tenant_scoped_only(tenant.id).find_by(public_id: params[:public_id].to_s)&.invite
    stash_pending_invite!(invite) if invite && !invite.expired?
  end

  # The login wall has already redirected on a login-required tenant. This
  # covers login-optional ones, where it lets a logged-out visitor through.
  def require_login_for_claim
    return if @current_user

    redirect_to "/login"
  end

  # The membership gate has already acted on a login-required tenant, and on
  # a login-optional one the activation gate turns a non-member away before
  # this runs; only operators, exempt from activation, reach it as
  # non-members. The rule is the membership gate's
  # (ApplicationController#validate_authenticated_access): an open tenant
  # adds anyone who logs in, an invite-only one needs an invite.
  def require_membership_for_claim
    return if current_tenant.tenant_users.exists?(user: current_user)

    if current_tenant.require_invite?
      redirect_to invite_required_path
    else
      current_tenant.add_user!(current_user)
    end
  end

  # The verified email is how the addressee is identified, so the claim needs
  # it even on a tenant whose activation checklist does not.
  def require_verified_email_for_claim
    return if current_user.email_verified?

    @signup = nil
    render_unavailable(:unverified_email)
  end

  def load_signup
    @signup = AgentSignup.tenant_scoped_only(current_tenant.id).find_by(public_id: params[:public_id].to_s)
    render status: :not_found, plain: "404 not found" if @signup.nil?
  end

  # Checked before any state, so a signup's state is never shown to anyone
  # but its addressee.
  def require_addressee
    return if @signup.addressed_to?(current_user)

    render_unavailable(:not_addressed)
  end

  def set_page_chrome
    @page_title = "Claim agent"
  end

  # Pairing check, agent creation and the claim happen under one row lock so
  # two submissions cannot both create an agent.
  def accept_under_lock
    outcome = nil
    result = nil
    @signup.with_lock do
      if !@signup.claimable_by?(current_user)
        outcome = :unavailable
      elsif !@signup.verify_pairing_code!(params[:pairing_code])
        outcome = :wrong_code
      else
        result = AiAgentCreationService.call(
          api_helper: api_helper(params: creation_params),
          billing_confirmed: params[:confirm_billing] == "1",
          responsibility_confirmed: true # checked before the lock, in accept
        )
        outcome = result.status
        @signup.claim!(ai_agent: result.ai_agent) if result.created?
      end
    end
    [outcome, result]
  end

  # The agent proposed only a name and handle; everything else is the
  # principal's choice on this page. Signup always creates an external agent.
  def creation_params
    params.slice(:name, :handle, :identity_prompt, :capabilities, :allow_public_writes).merge(mode: "external")
  end

  def finish_claim(ai_agent)
    SecurityAuditLog.log_agent_signup_claimed(signup: @signup, ip: request.remote_ip)

    if ai_agent.pending_billing_setup?
      flash[:notice] = "#{ai_agent.display_name} is claimed. Set up billing to activate them."
      return redirect_to "/billing"
    end

    handle = ai_agent.tenant_users.find_by(tenant_id: current_tenant.id)&.handle
    # Short: the agent's page carries its own "waiting to collect" notice.
    flash[:notice] = "#{ai_agent.display_name} is claimed."
    redirect_to ai_agent_path(handle)
  end

  def render_claim_form(status: :ok)
    @form_name = params[:name] || @signup.proposed_name
    @form_handle = params[:handle] || @signup.proposed_handle.to_s.parameterize(preserve_case: true)
    # On a re-render, keep what the principal chose. nil means "not submitted
    # yet", which the partials read as their defaults.
    @form_capabilities = Array(params[:capabilities]).compact_blank if params.key?(:capabilities)
    @form_allow_public_writes = ActiveModel::Type::Boolean.new.cast(params[:allow_public_writes]) if params.key?(:allow_public_writes)
    @billing_setup_required = current_user.requires_stripe_billing?(current_tenant)
    if @billing_setup_required
      session[:billing_return_to] = claim_path
    elsif current_tenant.feature_enabled?("stripe_billing")
      @proration_amount_cents = StripeService.preview_proration(current_user)
    end
    render :show, status: status
  end

  def render_unavailable(reason = nil)
    @reason = reason || unavailable_reason
    status = {
      unverified_email: :forbidden,
      not_addressed: :forbidden,
      expired: :gone,
      declined: :gone,
      claimed: request.get? ? :ok : :conflict,
    }.fetch(@reason)
    @claimed_agent_handle = @signup&.ai_agent_user&.tenant_users&.find_by(tenant_id: current_tenant.id)&.handle if @reason == :claimed
    render :unavailable, status: status
  end

  def unavailable_reason
    return :declined if @signup.state == "declined"
    return :claimed if ["claimed", "redeemed"].include?(@signup.state)

    :expired
  end

  def claim_path
    "/agent-signups/#{@signup.public_id}/claim"
  end
end
