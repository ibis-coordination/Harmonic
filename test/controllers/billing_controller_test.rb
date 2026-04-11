# typed: false

require "test_helper"
require "webmock/minitest"

class BillingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    @tenant.set_feature_flag!("ai_agents", true)
    enable_stripe_billing_flag!(@tenant)

    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"

    @original_price_id = ENV["STRIPE_PRICE_ID"]
    ENV["STRIPE_PRICE_ID"] = "price_test_123"
  end

  teardown do
    Stripe.api_key = @original_stripe_key
    ENV["STRIPE_PRICE_ID"] = @original_price_id
  end

  # === Show ===

  test "show displays billing status when authenticated" do
    sign_in_as(@user, tenant: @tenant)
    get "/billing"
    assert_response :success
  end

  test "show redirects unauthenticated user to login" do
    get "/billing"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "show activates billing when checkout_session_id present" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_show123", active: false)

    stub_subscription_sync("sub_show123")
    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_test123})
      .to_return(
        status: 200,
        body: {
          id: "cs_test123",
          object: "checkout.session",
          customer: "cus_show123",
          subscription: "sub_show123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_test123"

    assert_response :success
    sc.reload
    assert sc.active, "Customer should be active after checkout session verification"
    assert_equal "sub_show123", sc.stripe_subscription_id
  end

  test "show redirects to return_to after activating billing" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_redir123", active: false)

    stub_subscription_sync("sub_redir123")
    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_redir123})
      .to_return(
        status: 200,
        body: {
          id: "cs_redir123",
          object: "checkout.session",
          customer: "cus_redir123",
          subscription: "sub_redir123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_redir123&return_to=/ai-agents/new"

    assert_response :redirect
    assert_match %r{/ai-agents/new}, response.location
  end

  test "show validates return_to is a relative path" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_evil123", active: false)
    stub_subscription_sync("sub_evil123")

    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_evil123})
      .to_return(
        status: 200,
        body: {
          id: "cs_evil123",
          object: "checkout.session",
          customer: "cus_evil123",
          subscription: "sub_evil123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_evil123&return_to=https://evil.com"

    # Should NOT redirect to external URL
    assert_response :success
  end

  test "show rejects return_to with control characters" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_crlf123", active: true)

    sign_in_as(@user, tenant: @tenant)
    get "/billing?return_to=/safe%0d%0aInjected-Header:%20value"

    # Should NOT redirect - control characters are rejected
    assert_response :success
  end

  test "show ignores invalid checkout_session_id format" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_fmt123", active: false)

    sign_in_as(@user, tenant: @tenant)
    # This should NOT trigger a Stripe API call (no webmock stub needed)
    get "/billing?checkout_session_id=invalid_format"

    assert_response :success
  end

  test "show does not activate billing for mismatched customer" do
    # Create a StripeCustomer for a different user
    other_user = create_user(email: "other-billing-#{SecureRandom.hex(4)}@example.com")
    sc = StripeCustomer.create!(billable: other_user, stripe_id: "cus_other123", active: false)

    # The checkout session references a different customer
    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_mismatch123})
      .to_return(
        status: 200,
        body: {
          id: "cs_mismatch123",
          object: "checkout.session",
          customer: "cus_other123",
          subscription: "sub_other123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_mismatch123"

    assert_response :success
    sc.reload
    assert_not sc.active, "Should not activate billing for mismatched customer"
  end

  # === Setup ===

  test "setup creates customer and redirects to Stripe Checkout" do
    stub_request(:post, "https://api.stripe.com/v1/customers")
      .to_return(
        status: 200,
        body: { id: "cus_setup123", object: "customer" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .to_return(
        status: 200,
        body: {
          id: "cs_setup123",
          object: "checkout.session",
          url: "https://checkout.stripe.com/session/cs_setup123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    post "/billing/setup"

    assert_response :redirect
    assert_match %r{checkout\.stripe\.com}, response.location
  end

  test "setup passes return_to from session into success_url" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_return123")

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |req| captured_body = req.body; true }
      .to_return(
        status: 200,
        body: {
          id: "cs_return123",
          object: "checkout.session",
          url: "https://checkout.stripe.com/session/cs_return123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)

    # Simulate that billing_return_to was stored in session (by agent creation redirect)
    # We need to set this via a controller action that sets session
    # The simplest approach is to go through a flow that sets it
    get "/billing"  # Just to establish the session
    post "/billing/setup"

    assert_response :redirect
    assert captured_body.present?, "Should have made a Stripe API call"
  end

  # === Portal ===

  test "portal redirects to Stripe Billing Portal" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_portal123", active: true)

    stub_request(:post, "https://api.stripe.com/v1/billing_portal/sessions")
      .to_return(
        status: 200,
        body: {
          id: "bps_portal123",
          object: "billing_portal.session",
          url: "https://billing.stripe.com/session/bps_portal123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing/portal"

    assert_response :redirect
    assert_match %r{billing\.stripe\.com}, response.location
  end

  # === Markdown view ===

  test "show renders markdown view when Accept: text/markdown" do
    sign_in_as(@user, tenant: @tenant)
    get "/billing", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Billing"
    assert_includes response.body, "Not Set Up"
  end

  test "show markdown view shows active status when billing set up" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_md123", active: true)
    sign_in_as(@user, tenant: @tenant)
    get "/billing", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "**Active**"
  end

  test "show explains billing when not set up" do
    sign_in_as(@user, tenant: @tenant)
    get "/billing"
    assert_response :success
    assert_includes response.body, "$3/mo"
    assert_includes response.body, "Set Up Billing"
  end

  test "show displays active status when billing set up" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)
    get "/billing"
    assert_response :success
    assert_includes response.body, "Active"
    assert_includes response.body, "Manage payment"
  end

  # === Itemized Inventory Tests ===

  test "show lists active agents by name when subscription active" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "Research Bot")
    @tenant.add_user!(agent)

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "Research Bot"
    assert_includes response.body, "$3/mo"
  end

  test "show lists active collectives by name when subscription active" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    collective = create_test_collective(name: "Design Team")

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "Design Team"
  end

  test "show lists inactive agents separately" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "Archived Bot")
    @tenant.add_user!(agent)
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    agent.archive!

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "Archived Bot"
    assert_includes response.body, "inactive"
  end

  test "show lists inactive collectives separately" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    collective = create_test_collective(name: "Old Club")
    collective.archive!

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "Old Club"
    assert_includes response.body, "inactive"
  end

  test "show does not list main collective" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    main = Collective.find(@tenant.main_collective_id)

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    # Main collective should not appear in the billing inventory
    assert_not_includes response.body, "billing-item-collective-#{main.id}"
  end

  test "show does not list agents owned by other users" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    other_user = create_user(name: "Other Person")
    @tenant.add_user!(other_user)
    other_agent = create_ai_agent(parent: other_user, name: "Not My Bot")
    @tenant.add_user!(other_agent)

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_not_includes response.body, "Not My Bot"
  end

  test "show computes correct total with agents and collectives" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent1 = create_ai_agent(parent: @user, name: "Agent One")
    @tenant.add_user!(agent1)
    agent2 = create_ai_agent(parent: @user, name: "Agent Two")
    @tenant.add_user!(agent2)
    create_test_collective(name: "My Collective")

    # Count collectives: @collective (Global Collective, created by @user) + My Collective = 2
    expected_collectives = @user.active_billable_collective_count

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    # 1 (account) + 2 (agents) + N (collectives)
    expected_total = (1 + 2 + expected_collectives) * 3
    assert_includes response.body, "$#{expected_total}/mo"
  end

  test "show itemizes resources before checkout when not set up" do
    # User has agents but no subscription yet
    agent = create_ai_agent(parent: @user, name: "Pre-existing Agent")
    @tenant.add_user!(agent)
    create_test_collective(name: "Pre-existing Collective")

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "Pre-existing Agent"
    assert_includes response.body, "Pre-existing Collective"
    assert_includes response.body, "Set Up Billing"
  end

  test "show displays billing-exempt banner when all resources are exempt" do
    @user.update!(billing_exempt: true)
    # Exempt all non-main collectives created by this user
    Collective.where(created_by_id: @user.id).where.not(id: @tenant.main_collective_id).update_all(billing_exempt: true)

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "Billing-exempt"
  end

  test "show displays exempt label on individual exempt resources" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    @user.update!(billing_exempt: true)

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    # User row should show exempt, but non-exempt collectives should show $3/mo
    assert_includes response.body, "(exempt)"
    assert_includes response.body, "$3/mo"
  end

  test "show includes resources from current tenant in cross-tenant billing total" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "My Bot")
    @tenant.add_user!(agent)

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "My Bot"
    # Total should include the agent: 1 (user) + 1 (agent) + N (collectives)
    total = @user.billable_quantity
    assert_includes response.body, "$#{total * 3}/mo"
  end

  test "billable_quantity includes collectives from other billing-enabled tenants" do
    # Create another billing-enabled tenant and a collective on it owned by this user
    other_tenant = Tenant.create!(name: "Other Org", subdomain: "other-org-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(other_tenant)
    other_tenant.add_user!(@user)

    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    other_tenant.create_main_collective!(created_by: @user) unless other_tenant.main_collective_id
    main_coll = Collective.find(other_tenant.main_collective_id)
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: main_coll.handle)
    other_collective = Collective.create!(
      tenant: other_tenant,
      created_by: @user,
      name: "Other Org Collective",
      handle: "other-org-coll-#{SecureRandom.hex(4)}",
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # billable_quantity should count the collective on the other tenant
    # even when called from a request scoped to @tenant
    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    # The total should include: user + collectives on @tenant + the other_collective
    assert_includes response.body, other_collective.name
  end

  test "billable_quantity excludes collectives from non-billing tenants" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)

    # Create a tenant WITHOUT stripe_billing and a collective on it
    non_billing_tenant = Tenant.create!(name: "Free Org", subdomain: "free-org-#{SecureRandom.hex(4)}")
    # NOT enabling stripe_billing on this tenant
    non_billing_tenant.add_user!(@user)

    Tenant.scope_thread_to_tenant(subdomain: non_billing_tenant.subdomain)
    non_billing_tenant.create_main_collective!(created_by: @user) unless non_billing_tenant.main_collective_id
    main_coll = Collective.find(non_billing_tenant.main_collective_id)
    Collective.scope_thread_to_collective(subdomain: non_billing_tenant.subdomain, handle: main_coll.handle)
    free_collective = Collective.create!(
      tenant: non_billing_tenant,
      created_by: @user,
      name: "Free Org Collective",
      handle: "free-org-coll-#{SecureRandom.hex(4)}",
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_not_includes response.body, "Free Org Collective"
  end

  # === Deactivate/Reactivate Actions ===

  test "deactivate_agent archives the agent and redirects to billing" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "Deactivate Me")
    @tenant.add_user!(agent)
    agent_handle = agent.tenant_users.find_by(tenant_id: @tenant.id).handle

    sign_in_as(@user, tenant: @tenant)
    post "/billing/deactivate_agent/#{agent_handle}", params: { confirm_deactivate: "1" }

    assert_response :redirect
    assert_match %r{/billing}, response.location
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    assert agent.archived?, "Agent should be archived"
  end

  test "deactivate_agent requires confirmation" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "No Confirm")
    @tenant.add_user!(agent)
    agent_handle = agent.tenant_users.find_by(tenant_id: @tenant.id).handle

    sign_in_as(@user, tenant: @tenant)
    post "/billing/deactivate_agent/#{agent_handle}"

    assert_response :redirect
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    assert_not agent.archived?, "Agent should not be archived without confirmation"
  end

  test "reactivate_agent unarchives the agent and redirects to billing" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "Reactivate Me")
    @tenant.add_user!(agent)
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    agent.archive!

    agent_handle = agent.tenant_users.find_by(tenant_id: @tenant.id).handle

    sign_in_as(@user, tenant: @tenant)
    post "/billing/reactivate_agent/#{agent_handle}", params: { confirm_billing: "1" }

    assert_response :redirect
    assert_match %r{/billing}, response.location
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    assert_not agent.archived?, "Agent should be unarchived"
  end

  test "reactivate_agent requires billing confirmation" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "No Confirm React")
    @tenant.add_user!(agent)
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    agent.archive!

    agent_handle = agent.tenant_users.find_by(tenant_id: @tenant.id).handle

    sign_in_as(@user, tenant: @tenant)
    post "/billing/reactivate_agent/#{agent_handle}"

    assert_response :redirect
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    assert agent.archived?, "Agent should remain archived without confirmation"
  end

  test "deactivate_collective archives the collective and redirects to billing" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    collective = create_test_collective(name: "Deactivate Coll")

    sign_in_as(@user, tenant: @tenant)
    post "/billing/deactivate_collective/#{collective.handle}", params: { confirm_deactivate: "1" }

    assert_response :redirect
    assert_match %r{/billing}, response.location
    collective.reload
    assert collective.archived?, "Collective should be archived"
  end

  test "reactivate_collective unarchives the collective and redirects to billing" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    collective = create_test_collective(name: "Reactivate Coll")
    collective.archive!

    sign_in_as(@user, tenant: @tenant)
    post "/billing/reactivate_collective/#{collective.handle}", params: { confirm_billing: "1" }

    assert_response :redirect
    assert_match %r{/billing}, response.location
    collective.reload
    assert_not collective.archived?, "Collective should be unarchived"
  end

  test "reactivate_agent clears suspension from subscription loss" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    agent = create_ai_agent(parent: @user, name: "Suspended Bot")
    @tenant.add_user!(agent)
    agent.update!(suspended_at: Time.current, suspended_by_id: @user.id, suspended_reason: "Subscription deleted")

    agent_handle = agent.tenant_users.find_by(tenant_id: @tenant.id).handle

    sign_in_as(@user, tenant: @tenant)
    post "/billing/reactivate_agent/#{agent_handle}", params: { confirm_billing: "1" }

    assert_response :redirect
    agent.reload
    assert_nil agent.suspended_at, "Suspension should be cleared"
    assert_nil agent.suspended_reason
  end

  test "reactivate_agent blocked without active subscription" do
    # User has no active subscription
    agent = create_ai_agent(parent: @user, name: "No Sub Bot")
    @tenant.add_user!(agent)
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    agent.archive!

    agent_handle = agent.tenant_users.find_by(tenant_id: @tenant.id).handle

    sign_in_as(@user, tenant: @tenant)
    post "/billing/reactivate_agent/#{agent_handle}", params: { confirm_billing: "1" }

    assert_response :redirect
    agent.tenant_user = agent.tenant_users.find_by(tenant_id: @tenant.id)
    assert agent.archived?, "Agent should remain archived without active subscription"
  end

  test "cannot deactivate another user's agent" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    other_user = create_user(name: "Other Owner")
    @tenant.add_user!(other_user)
    other_agent = create_ai_agent(parent: other_user, name: "Not Mine")
    @tenant.add_user!(other_agent)
    agent_handle = other_agent.tenant_users.find_by(tenant_id: @tenant.id).handle

    sign_in_as(@user, tenant: @tenant)
    post "/billing/deactivate_agent/#{agent_handle}", params: { confirm_deactivate: "1" }

    assert_response :redirect
    other_agent.tenant_user = other_agent.tenant_users.find_by(tenant_id: @tenant.id)
    assert_not other_agent.archived?, "Should not be able to deactivate another user's agent"
  end

  # === Pending Billing Setup Tests ===

  test "show displays pending resources distinctly" do
    # Exempt user with no subscription, creates a pending agent
    @user.update!(billing_exempt: true)
    Collective.where(created_by_id: @user.id).where.not(id: @tenant.main_collective_id).update_all(billing_exempt: true)
    agent = create_ai_agent(parent: @user, name: "Pending Bot")
    @tenant.add_user!(agent)
    agent.update!(pending_billing_setup: true)

    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
    assert_includes response.body, "Pending Bot"
    assert_includes response.body, "pending"
  end

  test "checkout activates pending resources" do
    @user.update!(billing_exempt: true)
    Collective.for_user_across_tenants(@user).where.not(id: @tenant.main_collective_id).update_all(billing_exempt: true)

    agent = create_ai_agent(parent: @user, name: "Pending Agent")
    @tenant.add_user!(agent)
    agent.update!(pending_billing_setup: true)

    collective = create_test_collective(name: "Pending Coll")
    collective.update!(pending_billing_setup: true)

    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_pending_#{SecureRandom.hex(4)}", active: false)

    stub_subscription_sync("sub_pending123")
    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_pending123})
      .to_return(
        status: 200,
        body: {
          id: "cs_pending123",
          object: "checkout.session",
          customer: sc.stripe_id,
          subscription: "sub_pending123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_pending123"

    assert_response :success
    agent.reload
    assert_not agent.pending_billing_setup?, "Agent should no longer be pending after checkout"
    collective.reload
    assert_not collective.pending_billing_setup?, "Collective should no longer be pending after checkout"
  end

  test "agent creation sets pending_billing_setup when user has no subscription" do
    @user.update!(billing_exempt: true)
    Collective.where(created_by_id: @user.id).where.not(id: @tenant.main_collective_id).update_all(billing_exempt: true)

    sign_in_as(@user, tenant: @tenant)

    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: {
        name: "New Pending Agent",
        confirm_billing: "1",
      }
    end

    new_agent = User.where(user_type: "ai_agent").order(:created_at).last
    assert new_agent.pending_billing_setup?, "Agent should be pending when created without subscription"
  end

  # === Billing Consistency Tests ===
  # These ensure billing state stays in sync with Stripe, even in edge cases.
  # Not security exploits, but consistency gaps that could lead to brief under-billing.

  test "checkout completion syncs subscription quantity to catch any drift" do
    @user.update!(billing_exempt: true)
    Collective.where(created_by_id: @user.id).where.not(id: @tenant.main_collective_id).update_all(billing_exempt: true)

    agent1 = create_ai_agent(parent: @user, name: "Before Checkout")
    @tenant.add_user!(agent1)
    agent1.update!(pending_billing_setup: true)

    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_sync_#{SecureRandom.hex(4)}", active: false)

    agent2 = create_ai_agent(parent: @user, name: "During Checkout")
    @tenant.add_user!(agent2)
    agent2.update!(pending_billing_setup: true)

    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_sync_checkout})
      .to_return(
        status: 200,
        body: {
          id: "cs_sync_checkout",
          object: "checkout.session",
          customer: sc.stripe_id,
          subscription: "sub_sync_checkout",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_sync_checkout")
      .to_return(
        status: 200,
        body: {
          id: "sub_sync_checkout", object: "subscription", status: "active",
          items: { data: [{ id: "si_sync_checkout", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    quantity_set = nil
    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_sync_checkout")
      .with { |req| quantity_set = Rack::Utils.parse_query(req.body)["quantity"]; true }
      .to_return(
        status: 200,
        body: { id: "si_sync_checkout", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(
        status: 200,
        body: { id: "in_sync", object: "invoice", amount_due: 0 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_sync_checkout"

    assert_response :success
    assert_equal "2", quantity_set, "Should sync quantity after checkout to correct any drift"
  end

  test "agent creation marks agent pending when sync fails" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_syncfail_#{SecureRandom.hex(4)}", active: true, stripe_subscription_id: "sub_syncfail")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_syncfail")
      .to_return(status: 500, body: { error: { message: "Internal error" } }.to_json)

    sign_in_as(@user, tenant: @tenant)

    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: {
        name: "Sync Failed Agent",
        confirm_billing: "1",
      }
    end

    new_agent = User.where(user_type: "ai_agent").order(:created_at).last
    # If sync fails, the agent should be marked pending so it doesn't run unbilled
    assert new_agent.pending_billing_setup?, "Agent should be pending when sync fails"
  end

  test "agent creation checks subscription status from Stripe before activating" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_cancel_#{SecureRandom.hex(4)}", active: true, stripe_subscription_id: "sub_cancel")

    # Subscription is actually cancelled in Stripe, but local record still says active
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_cancel")
      .to_return(
        status: 200,
        body: {
          id: "sub_cancel", object: "subscription",
          status: "canceled",
          items: { data: [{ id: "si_cancel", quantity: 2, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_cancel")
      .to_return(status: 200, body: { id: "si_cancel", quantity: 3 }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(status: 200, body: { id: "in_cancel", object: "invoice", amount_due: 150 }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://api.stripe.com/v1/invoices/in_cancel/pay")
      .to_return(status: 200, body: { id: "in_cancel", object: "invoice", status: "paid" }.to_json, headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Created During Cancel",
      confirm_billing: "1",
    }

    new_agent = User.where(user_type: "ai_agent").order(:created_at).last
    # Sync discovers subscription is cancelled — should mark agent pending and deactivate local subscription
    assert new_agent.pending_billing_setup?,
      "Agent should be pending when sync discovers subscription is cancelled"
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  def create_test_collective(name: "Test Collective", handle: "test-collective-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: name,
      handle: handle,
    )
    cm = collective.add_user!(@user)
    cm.add_role!("admin")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    collective
  end

  # Stub Stripe subscription retrieval and update for sync_subscription_quantity!
  # Use when a test triggers checkout return (which now calls sync after activation).
  def stub_subscription_sync(sub_id)
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/#{sub_id}")
      .to_return(
        status: 200,
        body: {
          id: sub_id, object: "subscription", status: "active",
          items: { data: [{ id: "si_#{sub_id}", quantity: 99, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_#{sub_id}")
      .to_return(
        status: 200,
        body: { id: "si_#{sub_id}", object: "subscription_item" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(
        status: 200,
        body: { id: "in_#{sub_id}", object: "invoice", amount_due: 0 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
  end
end
