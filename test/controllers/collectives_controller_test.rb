require "test_helper"

class CollectivesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    # Make user an admin of the collective
    collective_member = @collective.collective_members.find_by(user: @user)
    collective_member.add_role!("admin") if collective_member
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def create_test_collective(name: "Test Collective", handle: "test-collective-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: name,
      handle: handle
    )
    cm = collective.add_user!(@user)
    cm.add_role!("admin")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    collective
  end

  # === Collectives Index Tests ===

  test "index shows only collectives the user is a member of" do
    sign_in_as(@user, tenant: @tenant)

    # Create a collective the user is NOT a member of
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    other_collective = Collective.create!(
      tenant: @tenant,
      created_by: other_user,
      name: "Secret Collective",
      handle: "secret-#{SecureRandom.hex(4)}"
    )
    other_collective.add_user!(other_user)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives"
    assert_response :success
    assert_includes response.body, @collective.name
    assert_not_includes response.body, "Secret Collective"
  end

  test "index excludes the main collective" do
    sign_in_as(@user, tenant: @tenant)

    get "/collectives"
    assert_response :success

    main_collective = Collective.find(@tenant.main_collective_id)
    assert_not_includes response.body, "pulse-home-list-name\">#{main_collective.name}"
  end

  # === Unauthenticated Access Tests ===

  test "unauthenticated user is redirected from collective homepage" do
    get "/collectives/#{@collective.handle}"
    assert_response :redirect
  end

  test "unauthenticated user is redirected from new collective form" do
    get "/collectives/new"
    assert_response :redirect
  end

  # === Show Collective Tests ===

  test "authenticated user can view collective homepage" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}"
    assert_response :success
  end

  # === New Collective Tests ===

  test "authenticated user can access new collective form" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/new"
    assert_response :success
  end

  # === Create Collective Tests ===

  test "authenticated user can create a collective" do
    sign_in_as(@user, tenant: @tenant)
    unique_handle = "new-collective-#{SecureRandom.hex(4)}"

    assert_difference "Collective.count", 1 do
      post "/collectives", params: {
        name: "New Collective",
        handle: unique_handle,
        description: "A new collective",
      }
    end

    collective = Collective.find_by(handle: unique_handle)
    assert_not_nil collective
    assert_equal "New Collective", collective.name
    assert_equal @user, collective.created_by
    assert_response :redirect
  end

  # === Settings Tests ===

  test "collective admin can access settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
  end

  test "non-admin cannot access collective settings" do
    other_user = create_user(name: "Regular User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    # Don't add admin role

    sign_in_as(other_user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    # Should show an error message (rendered with 200)
    assert_response :success
    assert_match(/admin/i, response.body)
  end

  # === Update Settings Tests ===

  test "collective admin can update settings" do
    sign_in_as(@user, tenant: @tenant)
    # Settings update uses POST, redirects to referrer so we need to set that header
    post "/collectives/#{@collective.handle}/settings",
         params: {
           name: "Updated Collective Name",
           description: "Updated description",
           timezone: "America/New_York",
           tempo: "weekly",
         },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_equal "Updated Collective Name", @collective.name
    assert_equal "Updated description", @collective.description
    assert_response :redirect
  end

  test "non-admin cannot update collective settings" do
    other_user = create_user(name: "Regular User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    original_name = @collective.name

    sign_in_as(other_user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { name: "Hacked Name" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_equal original_name, @collective.name
    assert_response :forbidden
  end

  # === Trio Flag Wiring ===

  test "enabling the trio feature flag activates trio for the collective" do
    @tenant.enable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", false)
    @collective.update!(tier: Collective::TIER_PAID)
    assert_nil @collective.trio_user_id, "precondition: trio should be off"

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { feature_trio: "true" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_not_nil @collective.trio_user_id, "expected trio to be activated"
    assert AutomationRule.where(ai_agent_id: @collective.trio_user_id).exists?, "expected default automations to be seeded"
  end

  test "disabling the trio feature flag deactivates trio for the collective" do
    @tenant.enable_feature_flag!("trio")
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("trio", true)
    TrioActivator.activate!(@collective)
    trio_id = T.must(@collective.reload.trio_user_id)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { feature_trio: "false" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_nil @collective.trio_user_id, "expected trio to be deactivated"
    rules = AutomationRule.where(ai_agent_id: trio_id)
    assert rules.all? { |r| !r.enabled? }, "expected default automations to be disabled"
  end

  # === Members Tests ===

  test "authenticated user can view collective members" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/members"
    assert_response :success
  end

  # === Invite Tests ===

  test "admin can access invite page" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/invite"
    assert_response :success
  end

  test "invite page has copy button separate from link box" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/invite"
    assert_response :success

    # Verify the invite link is in its own box
    assert_select ".pulse-invite-link-box" do
      assert_select "code.pulse-invite-link"
    end

    # Verify the copy button is in a separate actions section
    assert_select ".pulse-invite-actions" do
      assert_select "button.pulse-copy-btn.pulse-action-btn-secondary"
    end
  end

  # === Handle Available Tests ===

  test "handle_available returns true for available handle" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/available", params: { handle: "completely-new-handle-#{SecureRandom.hex(8)}" }
    assert_response :success

    json = JSON.parse(response.body)
    assert json["available"]
  end

  test "handle_available returns false for taken handle" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/available", params: { handle: @collective.handle }
    assert_response :success

    json = JSON.parse(response.body)
    assert_not json["available"]
  end

  test "handle_available returns false for reserved handle 'main'" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/available", params: { handle: "main" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_not json["available"]
  end

  # === Join Collective Tests ===

  test "user can view join page with valid invite code" do
    # Create a new collective for this test to avoid member conflicts
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    test_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Join Test Collective",
      handle: "join-test-#{SecureRandom.hex(4)}"
    )
    test_collective.add_user!(@user)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    # Re-establish tenant context — CurrentAttributes auto-reset clears it after sign_in_as request
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: test_collective.handle)
    invite = test_collective.find_or_create_shareable_invite(@user)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # Create a new user who is NOT a member of test_collective
    new_user = create_user(name: "New Member")
    @tenant.add_user!(new_user)
    # Don't add to test_collective

    sign_in_as(new_user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}/join", params: { code: invite.code }
    assert_response :success
  end

  # === Collective Billing and Archive Tests ===

  test "create succeeds without billing confirmation (collectives start at free tier)" do
    enable_stripe_billing_flag!(@tenant)
    handle = "free-tier-#{SecureRandom.hex(4)}"

    sign_in_as(@user, tenant: @tenant)

    assert_difference "Collective.count", 1 do
      post "/collectives", params: { name: "Free Tier Collective", handle: handle }
    end

    assert_response :redirect
    created = Collective.tenant_scoped_only(@tenant.id).find_by(handle: handle)
    assert_not_nil created
    assert_equal Collective::TIER_FREE, created.tier
  end

  test "settings page links to billing for archived collective instead of reactivation form" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    test_collective = create_test_collective
    test_collective.archive!

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}/settings"

    assert_response :success
    assert_includes response.body, "/billing"
    assert_not_includes response.body, "Reactivate Collective"
  end

  test "settings page links to billing for deactivation instead of form" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    test_collective = create_test_collective
    # Settings only links to /billing for paid_tier collectives; for free ones
    # there's nothing billing-related to manage.
    test_collective.update!(tier: Collective::TIER_PAID)

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}/settings"

    assert_response :success
    assert_includes response.body, "/billing"
    assert_not_includes response.body, "Deactivate Collective"
  end

  test "archived collective blocks write requests" do
    test_collective = create_test_collective
    test_collective.archive!

    sign_in_as(@user, tenant: @tenant)

    # Try to update settings on archived collective
    post "/collectives/#{test_collective.handle}/settings", params: { name: "New Name" }

    assert_response :redirect
    test_collective.reload
    assert_not_equal "New Name", test_collective.name
  end

  test "archived collective redirects to settings" do
    test_collective = create_test_collective
    test_collective.archive!

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}"

    assert_response :redirect
    assert_match %r{/settings}, response.location
  end

  # === Paid-tier gate on update_settings ===
  #
  # Paid feature flag flips are silently dropped on free collectives — the
  # rest of the form (name, description, etc.) still saves. The settings UI
  # hides the toggles on free collectives entirely, so this guards against
  # direct POSTs that bypass the UI.

  test "update_settings silently drops trio flip on free collective" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", false)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { name: @collective.name, feature_trio: "true" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_not @collective.trio_enabled?, "trio should remain off on a free collective"
    assert_not @collective.feature_flag_enabled_locally?("trio"), "flag should not have been written"
  end

  test "update_settings silently drops file_attachments flip on free collective" do
    enable_stripe_billing_flag!(@tenant)
    @collective.set_feature_flag!("file_attachments", false)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { name: @collective.name, feature_file_attachments: "true" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_not @collective.file_attachments_enabled?, "file_attachments should remain off on a free collective"
  end

  test "update_settings allows turning trio on for a paid collective" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @tenant.enable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", false)
    @collective.update!(tier: Collective::TIER_PAID)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { name: @collective.name, feature_trio: "true" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert @collective.trio_enabled?, "trio should activate when collective is paid"
  end

  test "update_settings always allows turning trio off" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @tenant.enable_feature_flag!("trio")
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("trio", true)
    TrioActivator.activate!(@collective)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { name: @collective.name, feature_trio: "false" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_not @collective.trio_enabled?
  end

  test "update_collective_settings_action (API) blocks turning file_uploads on for a free collective" do
    enable_stripe_billing_flag!(@tenant)
    @collective.set_feature_flag!("file_attachments", false)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings/actions/update_collective_settings",
         params: { file_uploads: "true" },
         headers: { "Accept" => "text/markdown" }

    @collective.reload
    assert_not @collective.file_attachments_enabled?, "file_attachments should not enable on a free collective"
    assert_includes response.body.downcase, "paid plan"
  end

  test "update_collective_settings_action (API) allows file_uploads on for a paid collective" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.set_feature_flag!("file_attachments", false)
    @collective.update!(tier: Collective::TIER_PAID)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings/actions/update_collective_settings",
         params: { file_uploads: "true" },
         headers: { "Accept" => "text/markdown" }

    @collective.reload
    assert @collective.file_attachments_enabled?
  end

  # === Tier badge rendering ===

  test "settings page renders Free plan badge when stripe_billing enabled and collective free" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
    assert_includes response.body, "Free plan"
    assert_not_includes response.body, "Paid plan"
  end

  test "settings page renders Paid plan badge when collective is paid_tier" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
    assert_includes response.body, "Paid plan"
  end

  test "settings page renders Billing lapsed badge when collective is lapsed" do
    enable_stripe_billing_flag!(@tenant)
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.update!(tier: Collective::TIER_LAPSED)
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
    assert_includes response.body, "Billing lapsed"
  end

  test "settings page renders no tier badge when stripe_billing flag is off" do
    # @tenant has no stripe_billing flag enabled — tier model is not in effect
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
    assert_not_includes response.body, "Free plan"
    assert_not_includes response.body, "Paid plan"
  end

  test "settings page shows Upgrade button on free collective" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
    assert_includes response.body, "Paid Plan Features"
    assert_match(/Upgrade to Paid/i, response.body)
  end

  test "settings page shows Paid Plan Features even when trio/file_attachments off at tenant level" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.set_feature_flag!("trio", false)
    @tenant.set_feature_flag!("file_attachments", false)
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
    assert_includes response.body, "Paid Plan Features"
    # On a free collective the section shows the explainer + Upgrade button,
    # not the Automations panel (that's paid-only).
    assert_match(/Upgrade to Paid/i, response.body)
  end

  test "settings page shows Downgrade button on paid collective for owner" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings"
    assert_response :success
    assert_includes response.body, "Downgrade to Free"
  end

  test "settings markdown view renders tier badge" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/settings", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "**Plan:**"
  end

  test "update_settings allows turning trio on when collective is already paid" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @tenant.enable_feature_flag!("trio")
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("file_attachments", true)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { name: @collective.name, feature_trio: "true" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    assert @collective.reload.trio_enabled?
  end

  # === Upgrade / Downgrade controller actions ===

  test "upgrade: owner with active stripe customer flips tier to paid inline" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    # Stub the quantity-sync call that fires after a successful upgrade.
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    assert_match %r{/settings}, response.location
    assert_equal Collective::TIER_PAID, @collective.reload.tier
    assert_match(/paid plan/i, flash[:notice].to_s)
  end

  test "upgrade: non-owner is rejected with 403" do
    other = create_user
    @tenant.add_user!(other)
    @collective.add_user!(other, roles: ["admin"])
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: other, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)

    sign_in_as(other, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :forbidden
    assert_equal Collective::TIER_FREE, @collective.reload.tier
  end

  test "upgrade: owner without billing is redirected to Stripe Checkout" do
    enable_stripe_billing_flag!(@tenant)
    @original_price_id = ENV["STRIPE_PRICE_ID"]
    ENV["STRIPE_PRICE_ID"] = "price_test_collective_upgrade"

    stub_request(:post, "https://api.stripe.com/v1/customers")
      .to_return(status: 200, body: { id: "cus_upgrade_test", object: "customer" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |req| captured_body = req.body; true }
      .to_return(status: 200, body: {
        id: "cs_upgrade_test",
        object: "checkout.session",
        url: "https://checkout.stripe.com/session/cs_upgrade_test",
      }.to_json, headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    assert_match %r{checkout\.stripe\.com}, response.location
    # Collective stays free until checkout.session.completed webhook fires.
    assert_equal Collective::TIER_FREE, @collective.reload.tier
    assert_match(/collective_id/, captured_body.to_s,
                 "expected collective_id in Checkout session metadata")
  ensure
    ENV["STRIPE_PRICE_ID"] = @original_price_id
  end

  test "upgrade: is idempotent on an already-paid collective" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    assert_equal Collective::TIER_PAID, @collective.reload.tier
  end

  test "downgrade: owner can downgrade a paid collective; clears flags and disables automations" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @tenant.enable_feature_flag!("trio")
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("trio", true)
    @collective.set_feature_flag!("file_attachments", true)
    rule = AutomationRule.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      name: "Rule", trigger_type: "manual", trigger_config: { "inputs" => {} },
      conditions: [], actions: {}, enabled: true,
    )
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade"

    assert_response :redirect
    @collective.reload
    assert_equal Collective::TIER_FREE, @collective.tier
    assert_not @collective.feature_flag_enabled_locally?("trio")
    assert_not @collective.feature_flag_enabled_locally?("file_attachments")
    assert_not rule.reload.enabled?
    assert_match(/downgraded/i, flash[:notice].to_s)
  end

  test "downgrade: non-owner is rejected with 403" do
    other = create_user
    @tenant.add_user!(other)
    @collective.add_user!(other, roles: ["admin"])
    @collective.update!(tier: Collective::TIER_PAID)

    sign_in_as(other, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade"

    assert_response :forbidden
    assert_equal Collective::TIER_PAID, @collective.reload.tier
  end

  test "downgrade: lapsed collective drops back to free" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.update!(tier: Collective::TIER_LAPSED)
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade"

    assert_response :redirect
    assert_equal Collective::TIER_FREE, @collective.reload.tier
  end

  test "downgrade: is idempotent on an already-free collective" do
    enable_stripe_billing_flag!(@tenant)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade"

    assert_response :redirect
    assert_equal Collective::TIER_FREE, @collective.reload.tier
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
