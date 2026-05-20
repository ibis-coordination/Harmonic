require "test_helper"

class ApiTokensControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.update!(main_collective_id: @collective.id) if @tenant.main_collective_id.nil?
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  def sign_in_for_tokens(user = @user)
    sign_in_with_reverification(user, tenant: @tenant, path: "/u/#{user.handle}/settings/tokens/new")
  end

  def token_handle
    @user.tenant_users.first.handle
  end

  def fake_checkout_url
    "https://checkout.stripe.example/cs_test_#{SecureRandom.hex(8)}"
  end

  # Wrap a block by stubbing StripeService.find_or_create_customer + create_checkout_session
  # so the controller redirects to a stable checkout URL without hitting Stripe.
  def stub_stripe_checkout(checkout_url: nil, &block)
    url = checkout_url || fake_checkout_url
    captured = { quantity: nil, success_url: nil, cancel_url: nil }
    sc = @user.stripe_customer ||
         StripeCustomer.create!(billable: @user, stripe_id: "cus_test_#{SecureRandom.hex(4)}", active: false)
    StripeService.stub :find_or_create_customer, sc do
      checkout_stub = lambda do |stripe_customer:, success_url:, cancel_url:, quantity:|
        captured[:quantity] = quantity
        captured[:success_url] = success_url
        captured[:cancel_url] = cancel_url
        url
      end
      StripeService.stub :create_checkout_session, checkout_stub do
        block.call(url, captured)
      end
    end
  end

  # === Pricing disclosure on the creation form ===

  test "GET new shows the $3/mo pricing notice for a fresh human when stripe_billing is enabled" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    get "/u/#{token_handle}/settings/tokens/new"

    assert_response :success
    assert_match(%r{\$3/month}i, response.body,
                 "expected pricing disclosure on the token creation form when stripe_billing is enabled")
  end

  test "GET new does NOT show pricing when stripe_billing is disabled" do
    sign_in_for_tokens

    get "/u/#{token_handle}/settings/tokens/new"

    assert_response :success
    assert_no_match(%r{\$3/month}i, response.body,
                    "free tenants should not show a billing disclosure")
  end

  test "GET new does NOT show pricing when user is already a billable token holder" do
    # User already has an active token AND an active subscription → they're
    # already paying, no new charge to confirm.
    enable_stripe_billing_flag!(@tenant)
    ApiToken.create!(user: @user, tenant: @tenant, name: "Pre-existing", scopes: ["read:all"])
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    sign_in_for_tokens

    get "/u/#{token_handle}/settings/tokens/new"

    assert_response :success
    assert_match(/API access is already on your subscription/i, response.body,
                 "expected an info line when API access is already billable")
  end

  # === POST create: redirect to Stripe when billing setup is needed ===

  test "POST create redirects to Stripe Checkout when user has no active subscription" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    initial_count = ApiToken.unscoped.where(user: @user).count

    stub_stripe_checkout do |url, captured|
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Needs Billing", read_write: "read" } }

      assert_response :redirect
      assert_equal url, response.location,
                   "expected redirect to Stripe Checkout URL when user has no subscription"
      assert_equal initial_count, ApiToken.unscoped.where(user: @user).count,
                   "token must NOT be created before billing is confirmed"
      assert_equal 1, captured[:quantity],
                   "expected Stripe quantity to include the pending token"
    end
  end

  test "POST create stashes the token params in session before redirecting to Stripe" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    stub_stripe_checkout do
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Pending Token", read_write: "write" } }
    end

    assert_equal "Pending Token", session[:pending_token_creation]["name"]
    assert_equal "write", session[:pending_token_creation]["read_write"]
    assert_equal @user.handle, session[:pending_token_creation]["user_handle"]
  end

  test "POST create includes the pending token in the Stripe quantity for users with existing billable resources" do
    enable_stripe_billing_flag!(@tenant)
    # User owns an additional non-main collective (billable_quantity = 1 already).
    create_collective(tenant: @tenant, created_by: @user, handle: "extra-#{SecureRandom.hex(4)}")
    sign_in_for_tokens

    stub_stripe_checkout do |_url, captured|
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Adds Token", read_write: "read" } }

      assert_equal 2, captured[:quantity],
                   "expected Stripe quantity to be existing billable + 1 for the pending token"
    end
  end

  test "POST create creates the token directly when user already has an active subscription" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    sign_in_for_tokens

    post "/u/#{token_handle}/settings/tokens",
         params: { api_token: { name: "Subscribed Token", read_write: "read" } }

    assert_response :success
    assert ApiToken.unscoped.exists?(user: @user, name: "Subscribed Token"),
           "active subscriber should get the token immediately"
  end

  test "POST create creates the token directly when stripe_billing is disabled" do
    sign_in_for_tokens

    post "/u/#{token_handle}/settings/tokens",
         params: { api_token: { name: "Free Tenant Token", read_write: "read" } }

    assert_response :success
    assert ApiToken.unscoped.exists?(user: @user, name: "Free Tenant Token")
  end

  test "POST create creates the token directly for sys_admin users (exempt from billing)" do
    @user.update!(sys_admin: true)
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    post "/u/#{token_handle}/settings/tokens",
         params: { api_token: { name: "Admin Token", read_write: "read" } }

    assert_response :success
    assert ApiToken.unscoped.exists?(user: @user, name: "Admin Token")
  end

  # === GET finalize: completes token creation after Stripe success ===

  test "GET finalize creates the pending token when the user now has active billing" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    # Step 1: user submits form, gets redirected to Stripe (token NOT created).
    stub_stripe_checkout do
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Finalized Token", read_write: "read" } }
    end
    initial_count = ApiToken.unscoped.where(user: @user).count

    # Step 2: simulate the Stripe callback marking the customer active.
    @user.reload.stripe_customer.update!(active: true)

    # Step 3: finalize creates the actual token.
    get "/u/#{token_handle}/settings/tokens/finalize"

    assert_response :success
    assert_equal initial_count + 1, ApiToken.unscoped.where(user: @user).count,
                 "expected the pending token to be created on finalize"
    assert ApiToken.unscoped.exists?(user: @user, name: "Finalized Token")
  end

  test "GET finalize preserves the duration the user selected on the form" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    stub_stripe_checkout do
      post "/u/#{token_handle}/settings/tokens",
           params: {
             api_token: { name: "Long-Lived", read_write: "read", duration: 6, duration_unit: "month(s)" },
           }
    end
    @user.reload.stripe_customer.update!(active: true)

    get "/u/#{token_handle}/settings/tokens/finalize"

    assert_response :success
    token = ApiToken.unscoped.find_by(user: @user, name: "Long-Lived")
    assert token, "expected token to be created"
    # Should expire ~6 months from now, NOT immediately (Time.current + 0).
    assert_in_delta 6.months.from_now.to_i, token.expires_at.to_i, 10.minutes.to_i,
                    "expected expires_at to reflect the form's selected duration (6 months), got #{token.expires_at}"
  end

  test "GET finalize clears the pending session after creating the token" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    stub_stripe_checkout do
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Clear Session", read_write: "read" } }
    end
    @user.reload.stripe_customer.update!(active: true)

    get "/u/#{token_handle}/settings/tokens/finalize"

    assert_nil session[:pending_token_creation],
               "expected pending_token_creation to be cleared after finalize succeeds"
  end

  test "GET finalize redirects to settings when there is no pending token creation" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    sign_in_for_tokens

    get "/u/#{token_handle}/settings/tokens/finalize"

    assert_response :redirect
    assert_match(%r{/settings\z}, response.location)
  end

  test "GET finalize clears pending and redirects to settings when billing is still not active (user canceled Stripe)" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    stub_stripe_checkout do
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Stuck Token", read_write: "read" } }
    end
    # Billing still NOT active — user must have canceled Stripe.

    get "/u/#{token_handle}/settings/tokens/finalize"

    assert_response :redirect
    assert_match(%r{/settings\z}, response.location,
                 "expected redirect to settings (not /billing) so the user starts the flow over")
    assert_match(/canceled/i, flash[:alert].to_s,
                 "expected an explanatory alert")
    assert_not ApiToken.unscoped.exists?(user: @user, name: "Stuck Token"),
               "no token should be created when billing isn't active"
    assert_nil session[:pending_token_creation],
               "stale pending must be cleared so a stray future /finalize visit doesn't materialize a forgotten token"
  end

  # === Pending AI agent loophole protection ===

  test "POST create refuses to create a token for an AI agent that is pending billing setup" do
    enable_stripe_billing_flag!(@tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent = create_ai_agent(parent: @user, name: "Pending Agent #{SecureRandom.hex(4)}",
                            agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    Tenant.clear_thread_scope
    agent.update!(pending_billing_setup: true)
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{agent.tenant_users.first.handle}/settings/tokens/new")

    initial_count = ApiToken.unscoped.where(user: agent).count
    post "/u/#{agent.tenant_users.first.handle}/settings/tokens",
         params: { api_token: { name: "Should Not Exist", read_write: "read" } }

    assert_response :redirect
    assert_match(%r{/billing}, response.location,
                 "expected redirect to /billing so the parent completes billing first")
    assert_equal initial_count, ApiToken.unscoped.where(user: agent).count,
                 "no token should be created for an agent that's pending billing setup"
  end

  # === Subscription sync after creation ===

  test "POST create with active subscription calls sync_subscription_quantity! after saving" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}",
                           stripe_subscription_id: "sub_#{SecureRandom.hex(4)}", active: true)
    sign_in_for_tokens

    sync_called_with = nil
    StripeService.stub :sync_subscription_quantity!, ->(user) { sync_called_with = user } do
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Synced Token", read_write: "read" } }
    end

    assert_equal @user, sync_called_with,
                 "expected sync_subscription_quantity! to be called for the user after creating their first billable token"
  end

  test "GET finalize calls sync_subscription_quantity! after creating the token" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_for_tokens

    stub_stripe_checkout do
      post "/u/#{token_handle}/settings/tokens",
           params: { api_token: { name: "Sync On Finalize", read_write: "read" } }
    end
    @user.reload.stripe_customer.update!(active: true, stripe_subscription_id: "sub_#{SecureRandom.hex(4)}")

    sync_called_with = nil
    StripeService.stub :sync_subscription_quantity!, ->(user) { sync_called_with = user } do
      get "/u/#{token_handle}/settings/tokens/finalize"
    end

    assert_equal @user, sync_called_with,
                 "expected sync_subscription_quantity! to be called defensively after finalize creates the token"
  end

  # === Deletion triggers subscription sync ===

  test "DELETE destroy calls StripeService.sync_subscription_quantity! when user has an active subscription" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_sync_#{SecureRandom.hex(4)}",
                           stripe_subscription_id: "sub_sync_#{SecureRandom.hex(4)}", active: true)
    token = ApiToken.create!(user: @user, tenant: @tenant, name: "Doomed", scopes: ["read:all"])
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{token_handle}/settings/tokens/#{token.id}")

    sync_called = false
    StripeService.stub :sync_subscription_quantity!, ->(user) { sync_called = true if user == @user } do
      delete "/u/#{token_handle}/settings/tokens/#{token.id}"
    end

    assert sync_called,
           "expected StripeService.sync_subscription_quantity! to be invoked when a human deletes a token while subscribed"
  end

  test "DELETE destroy does not call sync when user has no active subscription" do
    enable_stripe_billing_flag!(@tenant)
    token = ApiToken.create!(user: @user, tenant: @tenant, name: "Doomed", scopes: ["read:all"])
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{token_handle}/settings/tokens/#{token.id}")

    sync_called = false
    StripeService.stub :sync_subscription_quantity!, ->(_user) { sync_called = true } do
      delete "/u/#{token_handle}/settings/tokens/#{token.id}"
    end

    assert_not sync_called,
               "no subscription means no Stripe call to make"
  end
end
