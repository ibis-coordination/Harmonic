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

  end

  # POST /billing/setup
  def setup
    stripe_customer = StripeService.find_or_create_customer(current_user)

    return_to = session.delete(:billing_return_to)
    billing_url = billing_show_url
    success_url = "#{billing_url}?checkout_session_id={CHECKOUT_SESSION_ID}"
    success_url += "&return_to=#{CGI.escape(return_to)}" if return_to.present?

    checkout_url = StripeService.create_checkout_session(
      stripe_customer: stripe_customer,
      success_url: success_url,
      cancel_url: billing_url,
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
