# typed: false

class ApiTokensController < ApplicationController
  include RequiresReverification

  before_action :set_user
  before_action -> { require_reverification(scope: "api_tokens") }, only: [:new, :create, :finalize]
  before_action :set_sidebar_mode, only: [:new, :show, :create, :finalize]

  def show
    # Never show internal tokens
    @token = @showing_user.api_tokens.external.find_by(id: params[:id])
    return render status: :not_found, plain: "404 not token found" if @token.nil?

    respond_to do |format|
      format.html
      format.md
    end
  end

  def new
    # Only human accounts can create API tokens (for themselves or their ai_agents)
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create API tokens" unless current_user&.human?
    # Internal AI agents cannot have API tokens
    return render status: :forbidden, plain: "403 Forbidden - Internal AI agents cannot have API tokens" if @showing_user.internal_ai_agent?

    @token = @showing_user.api_tokens.new(user: @showing_user)
    @token.mcp_only = @showing_user.ai_agent?
    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    # Only human accounts can create API tokens (for themselves or their ai_agents)
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create API tokens" unless current_user&.human?
    # Internal AI agents cannot have API tokens
    return render status: :forbidden, plain: "403 Forbidden - Internal AI agents cannot have API tokens" if @showing_user.internal_ai_agent?

    # Refuse to issue a token for an AI agent that's pending billing setup.
    # Otherwise a parent could create an unbilled agent, then issue it a
    # token and use it for free (agent tokens skip the human billing gate).
    if @showing_user.ai_agent? && @showing_user.pending_billing_setup?
      flash[:alert] = "This AI agent is pending billing setup. Complete billing first to create a token for it."
      return redirect_to billing_show_path
    end

    # If the new token would make the user billable AND they have no active
    # subscription, redirect to Stripe Checkout instead of creating the token.
    # The token is created on return (via #finalize) after billing is active.
    if needs_stripe_setup_for_token?
      stash_pending_token_creation!
      return redirect_to_stripe_for_token_creation
    end

    @token = build_token(
      name: token_params[:name],
      read_write: token_params[:read_write],
      mcp_only: extract_mcp_only_from_params,
    )
    @token.save!
    sync_subscription_for_new_billable!
    flash.now[:notice] = "Token created successfully. Save the token value now - you will not be able to see it again."
    render "show"
  end

  # After Stripe Checkout returns, BillingController#handle_checkout_return
  # activates the customer and redirects here (via session[:billing_return_to]).
  # This action turns the stashed token params into a real ApiToken and
  # renders the show page so the user sees their plaintext token exactly once.
  def finalize
    pending = session[:pending_token_creation]
    if pending.nil? || pending["user_handle"] != @showing_user.handle
      # No flash — a user landing here without a pending creation is usually
      # following a stale link or got redirected from some other flow that
      # remembered this URL. Silently bouncing to settings is less alarming
      # than telling them a token they weren't trying to create is missing.
      return redirect_to "#{@showing_user.path}/settings"
    end

    # If the Stripe round-trip didn't activate billing (e.g. user canceled),
    # don't create the token. Clear the stash so a future stray visit to
    # /finalize doesn't materialize a token the user has forgotten about,
    # and tell them to start over.
    # NOTE: we check stripe_customer.active? directly rather than
    # requires_stripe_billing? because the latter short-circuits true when
    # billable_quantity is 0 — which it is at this point (the token doesn't
    # exist yet).
    if needs_stripe_setup_for_token? && !@showing_user.stripe_customer&.active?
      session.delete(:pending_token_creation)
      flash[:alert] = "Token creation canceled — billing wasn't set up. Try again when ready."
      return redirect_to "#{@showing_user.path}/settings"
    end

    session.delete(:pending_token_creation)
    @token = build_token(
      name: pending["name"],
      read_write: pending["read_write"],
      mcp_only: pending["mcp_only"].nil? ? @showing_user.ai_agent? : pending["mcp_only"],
    )
    # Restore the stashed expiry (the form's duration params aren't in this request).
    expires_at = pending["expires_at"]
    @token.expires_at = Time.zone.parse(expires_at) if expires_at.present?
    @token.save!
    # Defensive: usually the Stripe Checkout already set the right subscription
    # quantity (billable_quantity + 1 at form-submit time), but reconcile in
    # case the user created OTHER billable resources in another tab while
    # they were on Stripe. sync is a no-op when quantities already match.
    sync_subscription_for_new_billable!
    flash.now[:notice] = "Token created successfully. Save the token value now - you will not be able to see it again."
    render "show"
  end

  def destroy
    # Never allow deleting internal tokens
    @token = @showing_user.api_tokens.external.find_by(id: params[:id])
    return render status: :not_found, plain: "404 not token found" if @token.nil?

    @token.delete!
    # Drop the API-access surcharge from the user's subscription on next invoice
    # if this was their last billable token.
    StripeService.sync_subscription_quantity!(@showing_user) if @showing_user.human? && @showing_user.stripe_customer&.active?
    redirect_to "#{@showing_user.path}/settings"
  end

  # Markdown API actions

  def actions_index
    # Only human accounts can create API tokens
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create API tokens" unless current_user&.human?

    @page_title = "Actions | New API Token"
    render_actions_index(ActionsHelper.actions_for_route("/u/:handle/settings/tokens/new"))
  end

  def describe_create_api_token
    # Only human accounts can create API tokens
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create API tokens" unless current_user&.human?

    render_action_description(ActionsHelper.action_description("create_api_token", resource: @showing_user))
  end

  def execute_create_api_token
    # Only human accounts can create API tokens
    unless current_user&.human?
      return render_action_error({
                                   action_name: "create_api_token",
                                   resource: @showing_user,
                                   error: "Only human accounts can create API tokens.",
                                   status: :forbidden,
                                 })
    end
    # Internal AI agents cannot have API tokens
    if @showing_user.internal_ai_agent?
      return render_action_error({
                                   action_name: "create_api_token",
                                   resource: @showing_user,
                                   error: "Internal AI agents cannot have API tokens.",
                                   status: :forbidden,
                                 })
    end
    # Mirrors the browser-flow refusal above: don't issue tokens for AI agents
    # that are still pending billing setup.
    if @showing_user.ai_agent? && @showing_user.pending_billing_setup?
      return render_action_error({
                                   action_name: "create_api_token",
                                   resource: @showing_user,
                                   error: "This AI agent is pending billing setup. Complete billing in the browser first, then retry.",
                                 })
    end
    # The markdown / API surface is consumed by LLM agents, not browsers, so
    # there's no Stripe Checkout flow to redirect through. We refuse outright
    # if the user would become newly billable without active billing — the
    # human owner has to complete billing setup in the browser first.
    if needs_stripe_setup_for_token?
      return render_action_error({
                                   action_name: "create_api_token",
                                   resource: @showing_user,
                                   error: "Set up billing first (an API token costs $3/month). Visit /billing in your browser to add a payment method, then retry.",
                                 })
    end
    @token = build_token(
      name: params[:name],
      read_write: params[:read_write],
      mcp_only: if params.key?(:mcp_only)
                  [true, "true", "1"].include?(params[:mcp_only])
                else
                  @showing_user.ai_agent?
                end,
    )
    @token.save!
    sync_subscription_for_new_billable!

    respond_to do |format|
      format.md { render "show" }
      format.html { redirect_to @token.path }
    end
  end

  private

  def set_sidebar_mode
    @sidebar_mode = "minimal"
  end

  def token_params
    # duration_param is defined in the ApplicationController
    params.require(:api_token).permit(:name, :read_write, :mcp_only).merge(user: @showing_user)
  end

  # True when creating this token would make the user newly billable AND they
  # have no active Stripe subscription yet. Returning true means the controller
  # must route the user through Stripe Checkout before the token can be created.
  def needs_stripe_setup_for_token?
    return false unless @showing_user.human?
    return false unless current_tenant.feature_enabled?("stripe_billing")
    return false if @showing_user.app_admin? || @showing_user.sys_admin?
    return false if @showing_user.billing_exempt?
    return false if @showing_user.stripe_customer&.active?

    true
  end

  def stash_pending_token_creation!
    # expires_at is computed now (against the form's duration params), since
    # finalize runs without those params after the Stripe round-trip.
    session[:pending_token_creation] = {
      "user_handle" => @showing_user.handle,
      "name" => token_params[:name],
      "read_write" => token_params[:read_write],
      "mcp_only" => extract_mcp_only_from_params,
      "expires_at" => (Time.current + [duration_param, 1.year].min).iso8601,
    }
  end

  def redirect_to_stripe_for_token_creation
    stripe_customer = StripeService.find_or_create_customer(@showing_user)
    # Charge for everything the user owns + 1 for the pending token.
    quantity = @showing_user.billable_quantity + 1
    finalize_url = finalize_user_api_tokens_url(@showing_user)
    billing_url = billing_show_url
    success_url = "#{billing_url}?checkout_session_id={CHECKOUT_SESSION_ID}&return_to=#{CGI.escape(finalize_user_api_tokens_path(@showing_user))}"

    checkout_url = StripeService.create_checkout_session(
      stripe_customer: stripe_customer,
      success_url: success_url,
      cancel_url: finalize_url, # send cancels back through finalize too — it'll detect inactive billing and bounce to /billing
      quantity: quantity,
    )
    redirect_to checkout_url, allow_other_host: true
  end

  def build_token(name:, read_write:, mcp_only:)
    token = @showing_user.api_tokens.new
    token.name = name
    token.scopes = ApiToken.read_scopes
    token.scopes += ApiToken.write_scopes if read_write == "write"
    token.expires_at = Time.current + [duration_param, 1.year].min
    token.mcp_only = mcp_only
    token
  end

  # Resolve the form's `mcp_only` checkbox value (sent as "1"/"0") to a
  # boolean. Falls back to the user-type-based default when the field is
  # absent: agent tokens default true (the recommended secure mode), human
  # tokens default false (the check ignores human tokens anyway).
  def extract_mcp_only_from_params
    if token_params.key?(:mcp_only)
      ["1", "true", true].include?(token_params[:mcp_only])
    else
      @showing_user.ai_agent?
    end
  end

  # After saving a new token, push the updated billable_quantity to Stripe so
  # the user is charged proration immediately. No-op if they don't have an
  # active subscription (the Stripe-Checkout-first path handles charging
  # before the token is created).
  def sync_subscription_for_new_billable!
    return unless @showing_user.human?
    return unless @showing_user.stripe_customer&.active?
    StripeService.sync_subscription_quantity!(@showing_user)
  end

  def set_user
    handle = params[:user_handle] || params[:handle]
    tu = current_tenant.tenant_users.find_by(handle: handle)
    tu ||= current_tenant.tenant_users.find_by(user_id: handle)
    return render status: :not_found, plain: "404 not user found" if tu.nil?
    return render status: :forbidden, plain: "403 Unauthorized" unless current_user.can_edit?(tu.user)

    @showing_user = tu.user
    @showing_user.tenant_user = tu
  end
end
