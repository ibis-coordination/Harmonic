require "test_helper"

class NotificationWebhooksControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.set_feature_flag!("external_ai_agents", true)
    @collective = @global_collective
    @user = @global_user

    @other_human = create_user(name: "Other Human")
    @tenant.add_user!(@other_human)

    @external_agent = create_ai_agent(parent: @user, name: "External Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@external_agent)

    @internal_agent = create_ai_agent(parent: @user, name: "Internal Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "internal" })
    @tenant.add_user!(@internal_agent)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    sign_in_as(@user)

    @user_handle = @user.tenant_users.find_by(tenant: @tenant).handle
    @external_agent_handle = @external_agent.tenant_users.find_by(tenant: @tenant).handle
    @internal_agent_handle = @internal_agent.tenant_users.find_by(tenant: @tenant).handle
    @other_human_handle = @other_human.tenant_users.find_by(tenant: @tenant).handle
  end

  def create_webhook_for(owner)
    owner_attrs = owner.ai_agent? ? { ai_agent: owner } : { user: owner }
    AutomationRule.unscoped.create!(
      {
        tenant: @tenant,
        created_by: @user,
        name: "existing",
        trigger_type: "event",
        trigger_config: { "event_types" => ["notifications.delivered", "reminders.delivered"] },
        actions: {
          "webhook_url" => "https://existing.example.com/hook",
          "payload_template" => {},
        },
        webhook_secret: "whsec_existing",
        enabled: true,
      }.merge(owner_attrs)
    )
  end

  # === GET show ===

  test "GET show renders the create form when no webhook exists" do
    get "/u/#{@user_handle}/webhook"
    assert_response :success
    assert_select 'form input[name="webhook_url"]'
    assert_select "button", text: /Create webhook/i
  end

  test "GET show renders the manage view when a webhook exists" do
    rule = create_webhook_for(@user)
    get "/u/#{@user_handle}/webhook"
    assert_response :success
    assert_includes response.body, rule.actions["webhook_url"]
    assert_select "button", text: /Send test delivery/i
  end

  # === URL-prefix-aware target resolution ===

  test "/u/:handle/webhook 404s when handle resolves to an AI agent" do
    patch "/u/#{@external_agent_handle}/webhook", params: { webhook_url: "https://x.example.com/h" }
    assert_response :not_found
  end

  test "/ai-agents/:handle/webhook 404s when handle resolves to a human" do
    patch "/ai-agents/#{@user_handle}/webhook", params: { webhook_url: "https://x.example.com/h" }
    assert_response :not_found
  end

  test "/ai-agents/:handle/webhook 404s for internal agent" do
    patch "/ai-agents/#{@internal_agent_handle}/webhook", params: { webhook_url: "https://x.example.com/h" }
    assert_response :not_found
  end

  # === Authorization ===

  test "human cannot manage another human's webhook" do
    patch "/u/#{@other_human_handle}/webhook", params: { webhook_url: "https://x.example.com/h" }
    assert_response :redirect
  end

  test "non-parent cannot manage agent webhook" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_agent = create_ai_agent(parent: other_parent, name: "Other Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(other_agent)
    other_handle = other_agent.tenant_users.find_by(tenant: @tenant).handle

    patch "/ai-agents/#{other_handle}/webhook", params: { webhook_url: "https://x.example.com/h" }
    assert_response :redirect
  end

  # === PATCH /webhook (set URL, create-or-update) ===

  test "user can set their own webhook URL (creates rule)" do
    assert_difference "AutomationRule.count", 1 do
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://my-server.example.com/hook" }
    end
    # PRG: create redirects to the canonical show URL, secret in flash.
    assert_redirected_to "/u/#{@user_handle}/webhook"
    follow_redirect!
    assert_response :success
    assert_includes response.body, "whsec_" # secret revealed once

    rule = AutomationRule.last
    assert_equal "https://my-server.example.com/hook", rule.actions["webhook_url"]
    assert rule.webhook_secret.present?, "signing secret should be set on webhook_secret column"
    assert_equal @user.id, rule.user_id
    assert_equal ["notifications.delivered", "reminders.delivered"], rule.trigger_config["event_types"]
  end

  test "parent can set agent webhook URL (creates rule)" do
    assert_difference "AutomationRule.count", 1 do
      patch "/ai-agents/#{@external_agent_handle}/webhook", params: { webhook_url: "https://parent.example.com/hook" }
    end
    assert_redirected_to "/ai-agents/#{@external_agent_handle}/webhook"
    rule = AutomationRule.last
    assert_equal @external_agent.id, rule.ai_agent_id
  end

  test "patch updates existing rule's URL without creating a new one" do
    rule = create_webhook_for(@user)

    assert_no_difference "AutomationRule.count" do
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://updated.example.com/hook" }
    end
    assert_response :redirect

    rule.reload
    assert_equal "https://updated.example.com/hook", rule.actions["webhook_url"]
  end

  test "patch with http URL is rejected" do
    assert_no_difference "AutomationRule.count" do
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "http://insecure.example.com/hook" }
    end
    assert_response :unprocessable_entity
  end

  test "patch with blank URL is rejected" do
    assert_no_difference "AutomationRule.count" do
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "" }
    end
    assert_response :unprocessable_entity
  end

  test "patch with userinfo URL is rejected" do
    # Build via URI so the literal credentials-in-URL pattern doesn't trip
    # check-secrets.sh — the URL is the thing we're testing rejection of.
    uri = URI.parse("https://example.com/hook")
    uri.userinfo = "a:b"
    assert_no_difference "AutomationRule.count" do
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: uri.to_s }
    end
    assert_response :unprocessable_entity
  end

  test "validation error renders show with the rejected URL preserved" do
    patch "/u/#{@user_handle}/webhook", params: { webhook_url: "http://insecure.example.com/hook" }
    assert_response :unprocessable_entity
    # Renders the full show page (breadcrumb + form), not plain text.
    assert_select 'form input[name="webhook_url"][value=?]', "http://insecure.example.com/hook"
    assert_includes response.body, "Webhook URL must be a valid HTTPS URL."
  end

  test "validation error on update preserves the rejected URL in the edit form" do
    create_webhook_for(@user)
    patch "/u/#{@user_handle}/webhook", params: { webhook_url: "http://nope.example.com/x" }
    assert_response :unprocessable_entity
    # Existing-state branch — form input value is the rejected URL, not the saved one.
    assert_select 'form input[name="webhook_url"][value=?]', "http://nope.example.com/x"
  end

  # === DELETE ===

  test "delete removes the rule" do
    create_webhook_for(@user)

    assert_difference "AutomationRule.count", -1 do
      delete "/u/#{@user_handle}/webhook"
    end
    assert_response :redirect
  end

  # === Rotate ===

  test "rotate_secret generates new secret and reveals once" do
    rule = create_webhook_for(@user)
    old = rule.webhook_secret

    post "/u/#{@user_handle}/webhook/rotate_secret"
    # PRG: rotate redirects to the canonical show URL, secret in flash.
    assert_redirected_to "/u/#{@user_handle}/webhook"
    follow_redirect!
    assert_response :success
    assert_includes response.body, "whsec_"

    rule.reload
    assert_not_equal old, rule.webhook_secret
  end

  # === Toggle ===

  test "toggle enables a disabled webhook" do
    rule = create_webhook_for(@user)
    rule.update!(enabled: false)

    post "/u/#{@user_handle}/webhook/toggle"
    assert_response :redirect

    rule.reload
    assert rule.enabled?
  end

  test "toggle disables an enabled webhook" do
    rule = create_webhook_for(@user)
    rule.update!(enabled: true)

    post "/u/#{@user_handle}/webhook/toggle"
    assert_response :redirect

    rule.reload
    assert_not rule.enabled?
  end

  test "create makes the webhook enabled by default" do
    patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://my-server.example.com/hook" }
    assert_redirected_to "/u/#{@user_handle}/webhook"
    rule = AutomationRule.last
    assert rule.enabled?, "newly created webhook should be enabled"
  end

  # === Billing parity with API tokens ===

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  def stub_stripe_checkout(&block)
    url = "https://checkout.stripe.example/cs_test_#{SecureRandom.hex(8)}"
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

  test "human create redirects to Stripe Checkout when user has no active subscription" do
    enable_stripe_billing_flag!(@tenant)

    expected_quantity = @user.billable_quantity + 1
    stub_stripe_checkout do |url, captured|
      assert_no_difference "AutomationRule.unscoped.where(user_id: @user.id).count" do
        patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://my-server.example.com/hook" }
      end
      assert_redirected_to url
      assert_equal expected_quantity, captured[:quantity], "webhook adds +1 to existing billable_quantity"
    end
  ensure
    @tenant.disable_feature_flag!("stripe_billing")
  end

  test "human create proceeds when user already has an active stripe subscription" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)

    StripeService.stub :sync_subscription_quantity!, ->(_user) {} do
      assert_difference "AutomationRule.unscoped.where(user_id: @user.id).count", 1 do
        patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://my-server.example.com/hook" }
      end
    end
    assert_redirected_to "/u/#{@user_handle}/webhook"
  ensure
    @tenant.disable_feature_flag!("stripe_billing")
  end

  test "billing_exempt human bypasses the billing gate" do
    enable_stripe_billing_flag!(@tenant)
    @user.update!(billing_exempt: true)

    assert_difference "AutomationRule.unscoped.where(user_id: @user.id).count", 1 do
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://exempt.example.com/hook" }
    end
    assert_redirected_to "/u/#{@user_handle}/webhook"
  ensure
    @user.update!(billing_exempt: false)
    @tenant.disable_feature_flag!("stripe_billing")
  end

  test "admin human bypasses the billing gate" do
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)

    assert_difference "AutomationRule.unscoped.where(user_id: @user.id).count", 1 do
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://admin.example.com/hook" }
    end
    assert_redirected_to "/u/#{@user_handle}/webhook"
  ensure
    @user.update!(app_admin: false)
    @tenant.disable_feature_flag!("stripe_billing")
  end

  test "agent create skips the billing gate (agents are billed separately per active agent)" do
    enable_stripe_billing_flag!(@tenant)

    assert_difference "AutomationRule.unscoped.where(ai_agent_id: @external_agent.id).count", 1 do
      patch "/ai-agents/#{@external_agent_handle}/webhook", params: { webhook_url: "https://parent.example.com/hook" }
    end
    assert_redirected_to "/ai-agents/#{@external_agent_handle}/webhook"
  ensure
    @tenant.disable_feature_flag!("stripe_billing")
  end

  test "finalize is idempotent when a webhook already exists (two-tab race)" do
    enable_stripe_billing_flag!(@tenant)
    # Simulate the race: user round-trips through Stripe once, but somewhere
    # in there a webhook ended up persisted (e.g. another tab finished first).
    stub_stripe_checkout do |_url, _captured|
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://my-server.example.com/hook" }
    end
    @user.reload.stripe_customer.update!(active: true)
    create_webhook_for(@user) # webhook already exists when finalize runs

    StripeService.stub :sync_subscription_quantity!, ->(_user) {} do
      assert_no_difference "AutomationRule.unscoped.where(user_id: @user.id).count" do
        get "/u/#{@user_handle}/webhook/finalize"
      end
    end
    assert_redirected_to "/u/#{@user_handle}/webhook"
    follow_redirect!
    assert_includes response.body, "Billing set up"
  ensure
    @tenant.disable_feature_flag!("stripe_billing")
  end

  test "finalize creates the webhook after Stripe Checkout returns" do
    enable_stripe_billing_flag!(@tenant)
    # Step 1: PATCH triggers redirect to Stripe (no active customer yet) and
    # stashes the pending webhook creation in session.
    stub_stripe_checkout do |_url, _captured|
      patch "/u/#{@user_handle}/webhook", params: { webhook_url: "https://my-server.example.com/hook" }
    end
    # Step 2: Stripe Checkout succeeds → activate the customer.
    @user.reload.stripe_customer.update!(active: true)
    # Step 3: User returns via /finalize → webhook is created.
    StripeService.stub :sync_subscription_quantity!, ->(_user) {} do
      assert_difference "AutomationRule.unscoped.where(user_id: @user.id).count", 1 do
        get "/u/#{@user_handle}/webhook/finalize"
      end
    end
    assert_redirected_to "/u/#{@user_handle}/webhook"
  ensure
    @tenant.disable_feature_flag!("stripe_billing")
  end
end
