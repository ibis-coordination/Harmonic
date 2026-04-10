# typed: false

class BillingController < ApplicationController
  before_action :require_authentication
  before_action :set_sidebar_mode

  # GET /billing
  def show
    @page_title = "Billing"
    @stripe_customer = current_user.stripe_customer

    # Handle checkout return: verify session synchronously
    if params[:checkout_session_id].present?
      handle_checkout_return
    end

    # If billing is now active and there's a valid return_to, redirect
    return_to = params[:return_to]
    if @stripe_customer&.active? && safe_return_path?(return_to)
      return redirect_to return_to
    end

    load_billing_inventory

  end

  # POST /billing/setup
  def setup
    stripe_customer = StripeService.find_or_create_customer(current_user)

    return_to = session.delete(:billing_return_to)
    billing_url = billing_show_url
    success_url = "#{billing_url}?checkout_session_id={CHECKOUT_SESSION_ID}"
    success_url += "&return_to=#{CGI.escape(return_to)}" if return_to.present?

    quantity = current_user.billable_quantity(current_tenant)
    # Stripe requires quantity >= 1 for checkout
    quantity = [quantity, 1].max

    checkout_url = StripeService.create_checkout_session(
      stripe_customer: stripe_customer,
      success_url: success_url,
      cancel_url: billing_url,
      quantity: quantity,
    )

    redirect_to checkout_url, allow_other_host: true
  end

  # GET /billing/portal
  def portal
    stripe_customer = current_user.stripe_customer
    unless stripe_customer
      flash[:error] = "No billing account found. Please set up billing first."
      return redirect_to billing_show_path
    end

    portal_url = StripeService.create_portal_session(
      stripe_customer: stripe_customer,
      return_url: billing_show_url,
    )

    redirect_to portal_url, allow_other_host: true
  end

  def current_resource_model
    nil
  end

  private

  def set_sidebar_mode
    @sidebar_mode = "minimal"
  end

  def require_authentication
    redirect_to login_path unless current_user
  end

  def handle_checkout_return
    checkout_session_id = params[:checkout_session_id]
    unless checkout_session_id.match?(/\Acs_\w+\z/)
      Rails.logger.warn("[BillingController] Invalid checkout session ID format for user #{current_user.id}")
      return
    end

    session_obj = Stripe::Checkout::Session.retrieve(checkout_session_id)
    stripe_customer = current_user.stripe_customer

    # Only process if the checkout session matches the current user's customer
    unless stripe_customer && session_obj.customer == stripe_customer.stripe_id
      Rails.logger.warn("[BillingController] Checkout session customer mismatch for user #{current_user.id}")
      return
    end

    if !stripe_customer.active?
      stripe_customer.update!(
        stripe_subscription_id: session_obj.subscription,
        active: true,
      )
      @stripe_customer = stripe_customer.reload
      flash.now[:notice] = "Billing activated successfully!"
    end
  rescue Stripe::StripeError => e
    Rails.logger.warn("[BillingController] Checkout session handling failed: #{e.message}")
    flash.now[:error] = "Could not verify checkout session. Your billing may take a moment to activate."
  end

  def load_billing_inventory
    return unless current_tenant&.feature_enabled?("stripe_billing")

    # Active (billable) agents: owned by current user, on this tenant, not archived, not suspended
    @active_agents = current_user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant.id, archived_at: nil })
      .where(suspended_at: nil)
      .order(:name)

    # Inactive agents: owned by current user, on this tenant, archived or suspended
    @inactive_agents = current_user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant.id })
      .where("tenant_users.archived_at IS NOT NULL OR users.suspended_at IS NOT NULL")
      .order(:name)

    # Active (billable) collectives: created by current user, on this tenant, not archived, not main
    @active_collectives = Collective.where(
      tenant_id: current_tenant.id,
      created_by_id: current_user.id,
      archived_at: nil,
    ).where.not(id: current_tenant.main_collective_id).order(:name)

    # Inactive collectives: created by current user, on this tenant, archived, not main
    @inactive_collectives = Collective.where(
      tenant_id: current_tenant.id,
      created_by_id: current_user.id,
    ).where.not(archived_at: nil).where.not(id: current_tenant.main_collective_id).order(:name)

    @active_agent_count = @active_agents.where(billing_exempt: false).count
    @active_collective_count = @active_collectives.where(billing_exempt: false).count
    @billable_quantity = current_user.billable_quantity(current_tenant)

    # Cross-tenant notice: other tenants with stripe_billing enabled that this user belongs to
    other_tenant_ids = TenantUser.for_user_across_tenants(current_user)
      .where.not(tenant_id: current_tenant.id)
      .pluck(:tenant_id)
    if other_tenant_ids.any?
      @other_billing_tenants = Tenant.where(id: other_tenant_ids).select do |t|
        t.feature_enabled?("stripe_billing")
      end
    end
  end

  # Only allow relative paths (starts with /, no protocol/host) to prevent open redirect
  def safe_return_path?(path)
    return false if path.blank?
    return false unless path.start_with?("/")
    return false if path.start_with?("//") # protocol-relative URL
    return false if path.match?(/[\r\n\t\0]/) # reject control characters (CRLF injection)
    return false if path.match?(/[^a-zA-Z0-9\-._~:\/?#\[\]@!$&'()*+,;=%]/) # only valid URL chars

    true
  end
end
