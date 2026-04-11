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

    quantity = current_user.billable_quantity
    if quantity == 0
      flash[:notice] = "All your resources are exempt from billing. No subscription needed."
      return redirect_to billing_show_path
    end

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

  # POST /billing/deactivate_agent/:handle
  def deactivate_agent
    agent = find_owned_agent
    return redirect_to billing_show_path unless agent

    if params[:confirm_deactivate] != "1"
      flash[:error] = "You must confirm deactivation."
      return redirect_to billing_show_path
    end

    agent.archive!
    StripeService.sync_subscription_quantity!(current_user) if current_tenant.feature_enabled?("stripe_billing")
    flash[:notice] = "#{agent.display_name} has been deactivated."
    redirect_to billing_show_path
  end

  # POST /billing/reactivate_agent/:handle
  def reactivate_agent
    agent = find_owned_agent
    return redirect_to billing_show_path unless agent

    # Reactivating a non-exempt resource requires an active subscription
    if current_tenant.feature_enabled?("stripe_billing") && !agent.billing_exempt?
      unless current_user.stripe_customer&.active?
        flash[:error] = "You need an active subscription to reactivate resources. Please set up billing first."
        return redirect_to billing_show_path
      end

      if params[:confirm_billing] != "1"
        flash[:error] = "You must confirm the billing charge to reactivate this agent."
        return redirect_to billing_show_path
      end
    end

    # Clear suspension if the agent was suspended (e.g., from subscription loss)
    if agent.suspended_at.present?
      agent.update!(suspended_at: nil, suspended_by_id: nil, suspended_reason: nil)
    end
    agent.unarchive!
    charged_cents = nil
    result = StripeService.sync_subscription_quantity!(current_user) if current_tenant.feature_enabled?("stripe_billing")
    charged_cents = result&.charged_cents
    notice = "#{agent.display_name} has been reactivated."
    notice += " You were charged $#{format("%.2f", charged_cents / 100.0)} (prorated for the current billing period)." if charged_cents && charged_cents > 0
    flash[:notice] = notice
    redirect_to billing_show_path
  end

  # POST /billing/deactivate_collective/:collective_handle
  def deactivate_collective
    collective = find_owned_collective
    return redirect_to billing_show_path unless collective

    if params[:confirm_deactivate] != "1"
      flash[:error] = "You must confirm deactivation."
      return redirect_to billing_show_path
    end

    collective.archive!
    if current_tenant.feature_enabled?("stripe_billing")
      StripeService.sync_subscription_quantity!(current_user)
    end
    flash[:notice] = "#{collective.name} has been deactivated."
    redirect_to billing_show_path
  end

  # POST /billing/reactivate_collective/:collective_handle
  def reactivate_collective
    collective = find_owned_collective
    return redirect_to billing_show_path unless collective

    # Reactivating a non-exempt resource requires an active subscription
    if current_tenant.feature_enabled?("stripe_billing") && !collective.billing_exempt?
      unless current_user.stripe_customer&.active?
        flash[:error] = "You need an active subscription to reactivate resources. Please set up billing first."
        return redirect_to billing_show_path
      end

      if params[:confirm_billing] != "1"
        flash[:error] = "You must confirm the billing charge to reactivate this collective."
        return redirect_to billing_show_path
      end
    end

    collective.unarchive!
    charged_cents = nil
    result = StripeService.sync_subscription_quantity!(current_user) if current_tenant.feature_enabled?("stripe_billing")
    charged_cents = result&.charged_cents
    notice = "#{collective.name} has been reactivated."
    notice += " You were charged $#{format("%.2f", charged_cents / 100.0)} (prorated for the current billing period)." if charged_cents && charged_cents > 0
    flash[:notice] = notice
    redirect_to billing_show_path
  end

  def current_resource_model
    nil
  end

  private

  def activate_pending_resources!
    stripe_customer = current_user.stripe_customer

    # Activate ALL pending agents (cross-tenant — one subscription covers everything)
    # Also backfill stripe_customer_id for agents created before billing was set up
    pending_agents = current_user.ai_agents.where(pending_billing_setup: true)
    if stripe_customer
      pending_agents.where(stripe_customer_id: nil).update_all(stripe_customer_id: stripe_customer.id)
    end
    pending_agents.update_all(pending_billing_setup: false)

    # Activate ALL pending collectives (cross-tenant)
    Collective.for_user_across_tenants(current_user).where(
      pending_billing_setup: true,
    ).update_all(pending_billing_setup: false)
  end

  def find_owned_agent
    tu = TenantUser.where(tenant_id: current_tenant.id, handle: params[:handle]).first
    return nil unless tu

    agent = tu.user
    unless agent&.ai_agent? && agent.parent_id == current_user.id
      flash[:error] = "You can only manage your own agents."
      return nil
    end

    # Set tenant_user so archive!/unarchive! can find it
    agent.tenant_user = tu
    agent
  end

  def find_owned_collective
    collective = Collective.find_by(tenant_id: current_tenant.id, handle: params[:collective_handle])
    unless collective && collective.created_by_id == current_user.id
      flash[:error] = "You can only manage collectives you created."
      return nil
    end

    if collective.is_main_collective?
      flash[:error] = "The main collective cannot be deactivated."
      return nil
    end

    collective
  end

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

    # Only activate if checkout was actually completed (paid)
    unless session_obj.status == "complete"
      Rails.logger.warn("[BillingController] Checkout session #{checkout_session_id} not complete (status=#{session_obj.status}) for user #{current_user.id}")
      return
    end

    if !stripe_customer.active?
      # Lock the stripe_customer row to prevent concurrent checkout completions
      # and ensure pending resource activation is atomic with billing activation.
      StripeCustomer.transaction do
        stripe_customer.lock!
        # Re-check after acquiring lock (another request may have activated it)
        if !stripe_customer.active?
          stripe_customer.update!(
            stripe_subscription_id: session_obj.subscription,
            active: true,
          )

          # Activate any pending resources now that billing is set up
          activate_pending_resources!
        end
      end
      @stripe_customer = stripe_customer.reload

      # Sync quantity outside the transaction (calls Stripe API, shouldn't hold lock)
      StripeService.sync_subscription_quantity!(current_user)

      flash.now[:notice] = "Billing activated successfully!"
    end
  rescue Stripe::StripeError => e
    Rails.logger.warn("[BillingController] Checkout session handling failed: #{e.message}")
    flash.now[:error] = "Could not verify checkout session. Your billing may take a moment to activate."
  end

  def load_billing_inventory
    return unless current_tenant&.feature_enabled?("stripe_billing")

    # Get all tenants this user belongs to (for cross-tenant billing)
    billing_tenant_ids = current_user.billing_tenant_ids
    main_collective_ids = Tenant.where(id: billing_tenant_ids).pluck(:main_collective_id).compact

    # Active agents on billing-enabled tenants: not archived, not suspended, not pending
    @active_agents = current_user.ai_agents
      .joins(:tenant_users)
      .includes(:tenant_users)
      .where(tenant_users: { tenant_id: billing_tenant_ids, archived_at: nil })
      .where(suspended_at: nil, pending_billing_setup: false)
      .order(:name)

    # Pending agents on billing-enabled tenants
    @pending_agents = current_user.ai_agents
      .joins(:tenant_users)
      .includes(:tenant_users)
      .where(tenant_users: { tenant_id: billing_tenant_ids, archived_at: nil })
      .where(suspended_at: nil, pending_billing_setup: true)
      .order(:name)

    # Inactive agents on billing-enabled tenants: archived or suspended
    @inactive_agents = current_user.ai_agents
      .joins(:tenant_users)
      .includes(:tenant_users)
      .where(tenant_users: { tenant_id: billing_tenant_ids })
      .where("tenant_users.archived_at IS NOT NULL OR users.suspended_at IS NOT NULL")
      .order(:name)

    # Active collectives on billing-enabled tenants: not archived, not pending, not main
    @active_collectives = Collective.for_user_across_tenants(current_user).where(
      tenant_id: billing_tenant_ids,
      archived_at: nil,
      pending_billing_setup: false,
    ).where.not(id: main_collective_ids).includes(:tenant).order(:name)

    # Pending collectives on billing-enabled tenants
    @pending_collectives = Collective.for_user_across_tenants(current_user).where(
      tenant_id: billing_tenant_ids,
      archived_at: nil,
      pending_billing_setup: true,
    ).where.not(id: main_collective_ids).includes(:tenant).order(:name)

    # Inactive collectives on billing-enabled tenants: archived, not main
    @inactive_collectives = Collective.for_user_across_tenants(current_user).where(
      tenant_id: billing_tenant_ids,
    ).where.not(archived_at: nil).where.not(id: main_collective_ids).includes(:tenant).order(:name)

    @billable_quantity = current_user.billable_quantity
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
