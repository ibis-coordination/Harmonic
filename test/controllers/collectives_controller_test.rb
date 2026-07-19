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

    # Stripe SDK validates that api_key is set before sending requests, even
    # when the HTTP layer is stubbed by WebMock. Tests that hit Stripe paths
    # (upgrade flow, etc.) would otherwise raise Stripe::AuthenticationError
    # in CI where no Stripe.api_key is configured.
    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"
  end

  def teardown
    Stripe.api_key = @original_stripe_key
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

  # === Trio (Ensemble) Flag Wiring ===

  test "enabling the trio feature flag activates the ensemble for the collective" do
    @tenant.enable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", false)
    @collective.update!(tier: Collective::TIER_PAID)
    assert_nil @collective.persona_user("cadence")&.id, "precondition: cadence should be off"

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { feature_trio: "true" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_not_nil @collective.persona_user("cadence")&.id, "expected cadence to be activated"
    assert AutomationRule.where(ai_agent_id: @collective.persona_user("cadence")&.id).exists?, "expected default automations to be seeded"
  end

  test "disabling the trio feature flag deactivates the ensemble for the collective" do
    @tenant.enable_feature_flag!("trio")
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("trio", true)
    PersonaActivator.activate!(@collective)
    trio_id = T.must(@collective.reload.persona_user("cadence")&.id)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/settings",
         params: { feature_trio: "false" },
         headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/collectives/#{@collective.handle}/settings" }

    @collective.reload
    assert_nil @collective.persona_user("cadence")&.id, "expected cadence to be deactivated"
    rules = AutomationRule.where(ai_agent_id: trio_id)
    assert rules.all? { |r| !r.enabled? }, "expected default automations to be disabled"
  end

  # === Members Tests ===

  test "authenticated user can view collective members" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/members"
    assert_response :success
  end

  test "member rows link to the top-level /u/:handle, not the collective-scoped /m/" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/members"
    assert_response :success
    handle = @user.tenant_users.find_by(tenant_id: @tenant.id).handle
    assert_select "a.pulse-participant-name[href=?]", "/u/#{handle}"
    assert_select "a.pulse-participant-name[href*=?]", "/collectives/", false,
                  "member rows must not link to a collective-scoped profile"
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

  test "POST /join with an expired invite is rejected with a friendly message" do
    test_collective = create_test_collective
    expired = Invite.create!(
      tenant: @tenant, collective: test_collective, created_by: @user,
      code: SecureRandom.hex(8), expires_at: 1.day.ago,
    )
    member = create_user(name: "Expired Join Attempt")
    @tenant.add_user!(member)

    sign_in_as(member, tenant: @tenant)
    post "/collectives/#{test_collective.handle}/join", params: { code: expired.code }

    assert_response :redirect
    assert_match(/not valid|expired/i, flash[:alert].to_s,
                 "expected a friendly alert for an expired invite")
    assert_not test_collective.user_is_member?(member),
               "an expired invite must not grant collective membership"
  end

  test "POST /join with someone else's personal invite is rejected without a 500" do
    test_collective = create_test_collective
    intended = create_user(name: "Intended Recipient")
    @tenant.add_user!(intended)
    personal = Invite.create!(
      tenant: @tenant, collective: test_collective, created_by: @user,
      invited_user: intended, code: SecureRandom.hex(8), expires_at: 1.week.from_now,
    )
    interloper = create_user(name: "Interloper")
    @tenant.add_user!(interloper)

    sign_in_as(interloper, tenant: @tenant)
    post "/collectives/#{test_collective.handle}/join", params: { code: personal.code }

    assert_response :redirect
    assert_match(/not valid|expired/i, flash[:alert].to_s)
    assert_not test_collective.user_is_member?(interloper)
  end

  test "POST /join when already a member redirects to the collective instead of erroring" do
    test_collective = create_test_collective
    invite = Invite.create!(
      tenant: @tenant, collective: test_collective, created_by: @user,
      code: SecureRandom.hex(8), expires_at: 1.week.from_now,
    )
    # @user is already a member of test_collective via create_test_collective.

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{test_collective.handle}/join", params: { code: invite.code }

    assert_response :redirect
    assert_match(/#{Regexp.escape(test_collective.path)}/, response.location,
                 "a member double-submitting join should just land on the collective")
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

  test "settings page surfaces a Reactivate button on archived collective for the owner" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    test_collective = create_test_collective
    test_collective.archive!(actor: @user)

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}/settings"

    assert_response :success
    assert_includes response.body, "/collectives/#{test_collective.handle}/unarchive",
                    "settings page should expose the unarchive endpoint for the owner"
    assert_match(/Reactivate/i, response.body)
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

  test "free-tier upgrade copy omits the built-in agents when tenant has them disabled" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.set_feature_flag!("trio", false)
    @tenant.set_feature_flag!("file_attachments", false)
    test_collective = create_test_collective # starts at free tier

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}/settings"

    assert_response :success
    assert_includes response.body, "Upgrade to the paid plan"
    # Banner lists paid features mid-sentence (lowercase common nouns); when the
    # tenant has only Automations available, the copy says "unlock automations".
    assert_includes response.body, "unlock automations on this collective"
    assert_not_includes response.body, "built-in agents"
    assert_not_includes response.body, "file attachments"
  end

  test "paid-tier downgrade copy omits the built-in agents when tenant has them disabled" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.set_feature_flag!("trio", false)
    @tenant.set_feature_flag!("file_attachments", false)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    test_collective = create_test_collective
    test_collective.update!(tier: Collective::TIER_PAID)

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}/settings"

    assert_response :success
    assert_includes response.body, "Downgrade to Free"
    assert_not_includes response.body, "turn off Cadence"
    assert_not_includes response.body, "Cadence / file attachments"
  end

  test "free-tier upgrade copy includes the built-in agents and file attachments when tenant has them enabled" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    @tenant.enable_feature_flag!("file_attachments")
    test_collective = create_test_collective

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{test_collective.handle}/settings"

    assert_response :success
    assert_includes response.body, "the built-in agents (Melody, Counterpoint, and Cadence)"
    assert_includes response.body, "file attachments"
  end

  test "archived collective blocks write requests" do
    test_collective = create_test_collective
    test_collective.archive!(actor: @user)

    sign_in_as(@user, tenant: @tenant)

    # Try to update settings on archived collective
    post "/collectives/#{test_collective.handle}/settings", params: { name: "New Name" }

    assert_response :redirect
    test_collective.reload
    assert_not_equal "New Name", test_collective.name
  end

  test "archived collective redirects to settings" do
    test_collective = create_test_collective
    test_collective.archive!(actor: @user)

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
    PersonaActivator.activate!(@collective)

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

  test "settings page shows Paid Plan Features even when personas/file_attachments off at tenant level" do
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
    @original_price_id = ENV.fetch("STRIPE_PRICE_ID", nil)
    ENV["STRIPE_PRICE_ID"] = "price_test_collective_upgrade"

    stub_request(:post, "https://api.stripe.com/v1/customers")
      .to_return(status: 200, body: { id: "cus_upgrade_test", object: "customer" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with do |req|
      captured_body = req.body
      true
    end
      .to_return(status: 200, body: {
        id: "cs_upgrade_test",
        object: "checkout.session",
        url: "https://checkout.stripe.com/session/cs_upgrade_test",
      }.to_json, headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    assert_match(/checkout\.stripe\.com/, response.location)
    # Collective stays free until checkout.session.completed webhook fires.
    assert_equal Collective::TIER_FREE, @collective.reload.tier
    assert_match(/collective_id/, captured_body.to_s,
                 "expected collective_id in Checkout session metadata")
  ensure
    ENV["STRIPE_PRICE_ID"] = @original_price_id
  end

  # === Upgrade preview (GET) ===

  test "upgrade preview: owner sees preview page with $3/month notice" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/upgrade"

    assert_response :success
    assert_match(%r{\$3/month}, response.body)
    # Confirmation form must POST to /upgrade with Turbo opted out
    # (controller may redirect cross-origin to Stripe Checkout).
    assert_match %r{<form[^>]*action="[^"]*#{Regexp.escape(@collective.handle)}/upgrade"[^>]*method="post"[^>]*>}, response.body
    assert_match(/data-turbo="false"/, response.body)
  end

  test "upgrade preview: owner with active billing sees prorated charge amount" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_preview_test", active: true, stripe_subscription_id: "sub_preview_test")

    # Stub the proration preview Stripe API call
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/sub_preview_test})
      .to_return(status: 200, body: {
        id: "sub_preview_test",
        items: { data: [{ id: "si_test", quantity: 1 }] },
      }.to_json, headers: { "Content-Type" => "application/json" })
    # Stripe API 2026-02-25.clover: proration boolean is nested under
    # parent.subscription_item_details.proration, not at the top of the line.
    stub_request(:post, %r{https://api.stripe.com/v1/invoices/create_preview})
      .to_return(status: 200, body: {
        lines: { data: [{
          amount: 199,
          parent: { type: "subscription_item_details", subscription_item_details: { proration: true } },
        }] },
      }.to_json, headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/upgrade"

    assert_response :success
    assert_match(/\$1\.99/, response.body, "expected prorated amount $1.99 in preview")
    assert_match(/Confirm/i, response.body)
  end

  test "upgrade preview: owner without billing sees 'set up billing on next page' notice" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/upgrade"

    assert_response :success
    # No prorated charge to preview; must indicate user will set up billing
    assert_match(/billing|stripe checkout|set up/i, response.body)
  end

  test "upgrade preview: non-owner is forbidden" do
    other = create_user
    @tenant.add_user!(other)
    @collective.add_user!(other, roles: ["admin"])
    enable_stripe_billing_flag!(@tenant)

    sign_in_as(other, tenant: @tenant)
    get "/collectives/#{@collective.handle}/upgrade"

    assert_response :forbidden
  end

  test "upgrade preview: redirects already-paid collective back to settings" do
    enable_stripe_billing_flag!(@tenant)
    # Active billing so the app-level billing gate doesn't bounce us to /billing first.
    StripeCustomer.create!(billable: @user, stripe_id: "cus_paid_preview", active: true, stripe_subscription_id: "sub_paid_preview")
    @collective.update!(tier: Collective::TIER_PAID)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/upgrade"

    # No preview needed; nothing to confirm.
    assert_response :redirect
    assert_match %r{/settings}, response.location
  end

  # Repro for user-reported bug: clicking Upgrade as an owner with no
  # Stripe billing setup yields a "success" flash, but the collective stays
  # on the free plan and the user is never redirected to Stripe Checkout.
  #
  # Expected: BillingRequired raised → redirect to Stripe Checkout URL,
  # tier remains free until checkout completes. No "is now on the paid
  # plan" flash should appear on this path.
  test "upgrade repro: owner with no StripeCustomer must hit Stripe Checkout, not get success flash" do
    enable_stripe_billing_flag!(@tenant)
    @original_price_id = ENV.fetch("STRIPE_PRICE_ID", nil)
    ENV["STRIPE_PRICE_ID"] = "price_test_repro"

    stub_request(:post, "https://api.stripe.com/v1/customers")
      .to_return(status: 200, body: { id: "cus_repro_test", object: "customer" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .to_return(status: 200, body: {
        id: "cs_repro_test", object: "checkout.session",
        url: "https://checkout.stripe.com/session/cs_repro_test",
      }.to_json, headers: { "Content-Type" => "application/json" })

    assert_nil @user.stripe_customer, "precondition: user has no stripe_customer"
    assert_equal Collective::TIER_FREE, @collective.reload.tier, "precondition: collective is free"
    assert_not @user.sys_admin?, "precondition: user is not sys_admin"
    assert_not @user.app_admin?, "precondition: user is not app_admin"
    assert_not @collective.billing_exempt?, "precondition: collective is not billing_exempt"
    assert @tenant.feature_enabled?("stripe_billing"), "precondition: tenant has stripe_billing"
    assert_equal @user.id, @collective.created_by_id, "precondition: user owns the collective"

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    assert_match(/checkout\.stripe\.com/, response.location,
                 "expected redirect to Stripe Checkout; got #{response.location}")
    assert_nil flash[:notice], "no success flash should fire on the BillingRequired path; got: #{flash[:notice].inspect}"
    assert_equal Collective::TIER_FREE, @collective.reload.tier, "tier must remain free pending checkout"
  ensure
    ENV["STRIPE_PRICE_ID"] = @original_price_id
  end

  # Variant: user has a stripe_customer record from a prior attempt but it's
  # not active (subscription was never completed). Same expected behavior:
  # BillingRequired → Stripe Checkout, no success flash, tier stays free.
  test "upgrade repro: owner with inactive StripeCustomer still hits Stripe Checkout" do
    enable_stripe_billing_flag!(@tenant)
    @original_price_id = ENV.fetch("STRIPE_PRICE_ID", nil)
    ENV["STRIPE_PRICE_ID"] = "price_test_repro2"
    StripeCustomer.create!(billable: @user, stripe_id: "cus_inactive_test", active: false)

    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .to_return(status: 200, body: {
        id: "cs_repro2", object: "checkout.session",
        url: "https://checkout.stripe.com/session/cs_repro2",
      }.to_json, headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    assert_match(/checkout\.stripe\.com/, response.location)
    assert_nil flash[:notice]
    assert_equal Collective::TIER_FREE, @collective.reload.tier
  ensure
    ENV["STRIPE_PRICE_ID"] = @original_price_id
  end

  # Repro for the user-reported bug:
  #
  # Upgrade button is rendered with Turbo intercepting form submission. The
  # controller's BillingRequired path redirects to checkout.stripe.com
  # (cross-origin). Turbo Drive silently BLOCKS cross-origin redirects —
  # the form submits, server responds 302 to a different host, Turbo
  # refuses to navigate, user is stuck on the form with no error. The
  # turbo-confirm dialog ("Upgrade this collective to the paid plan?")
  # reads like a "success" message after the user clicks OK, even though
  # nothing actually happened server-side.
  #
  # Fix: opt the Upgrade form out of Turbo with `data: { turbo: false }`
  # so the browser handles the cross-origin redirect natively.
  # Settings page now links to the GET upgrade preview rather than POSTing
  # directly — the preview shows the prorated charge before any billing
  # action happens, and its own form opts out of Turbo for the actual POST.
  test "settings: Upgrade affordance is a GET link to the upgrade preview" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/settings"
    assert_response :success

    assert_match %r{<a[^>]*href="[^"]*#{Regexp.escape(@collective.handle)}/upgrade"[^>]*>[^<]*Upgrade}, response.body,
                 "settings page should link (not POST) to the upgrade preview"
  end

  # The upgrade preview's confirm form must opt out of Turbo because the
  # POST may redirect cross-origin to checkout.stripe.com, which Turbo
  # Drive silently blocks.
  test "upgrade preview confirm form opts out of Turbo" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/upgrade"
    assert_response :success

    form_match = response.body.match(
      %r{<form[^>]*action="[^"]*#{Regexp.escape(@collective.handle)}/upgrade"[^>]*method="post"[^>]*>}
    )
    assert form_match, "preview must contain a POST form to /upgrade"
    assert_match(/data-turbo="false"/, form_match[0],
                 "preview form must opt out of Turbo for the cross-origin Stripe Checkout redirect")
  end

  # Diagnostic variant: tenant has stripe_billing OFF. The Upgrade button
  # shouldn't be visible in the UI for this case, but if the form is somehow
  # submitted, `billing_covered_for_upgrade?` returns true (no billing
  # required on non-billing tenants) and the upgrade succeeds inline.
  # Verifies tier actually flips to paid.
  test "upgrade on a non-billing tenant is a no-op redirect (features already unlocked)" do
    # @tenant has stripe_billing OFF by default in this test setup. There's
    # no tier model in effect — tier_unlocks_paid_features? already returns
    # true — so "upgrade" must not flip the tier or imply a charge; it just
    # redirects back to settings.
    assert_not @tenant.feature_enabled?("stripe_billing"), "precondition: stripe_billing off"

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    assert_match %r{/settings}, response.location
    assert_equal Collective::TIER_FREE, @collective.reload.tier,
                 "non-billing-tenant upgrade must NOT flip tier; got #{@collective.tier.inspect}"
    assert_nil flash[:notice], "no 'now on the paid plan' flash on a no-op upgrade"
  end

  test "upgrade on the main collective is a no-op redirect (never billable)" do
    enable_stripe_billing_flag!(@tenant)
    main = @tenant.main_collective
    assert main.is_main_collective?, "precondition: main collective"

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{main.handle}/upgrade"

    assert_response :redirect
    assert_match %r{/settings}, response.location
    assert_equal Collective::TIER_FREE, main.reload.tier, "main collective must stay free"
    assert_nil flash[:notice],
               "main-collective upgrade must NOT flash a misleading 'now on the paid plan'"
  end

  # Diagnostic variant: actor is app_admin. The billing requirement is
  # waived for admins. Tier should flip to paid inline.
  test "upgrade diagnostic: app_admin actor succeeds inline and flips tier" do
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    @collective.reload
    assert_equal Collective::TIER_PAID, @collective.tier,
                 "tier must flip to paid for app_admin actor; got #{@collective.tier.inspect}"
  end

  # Diagnostic variant: collective is billing_exempt. Upgrade succeeds
  # inline without billing. Tier flips to paid.
  test "upgrade diagnostic: billing_exempt collective succeeds inline and flips tier" do
    enable_stripe_billing_flag!(@tenant)
    @collective.update!(billing_exempt: true)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/upgrade"

    assert_response :redirect
    @collective.reload
    assert_equal Collective::TIER_PAID, @collective.tier,
                 "tier must flip to paid for billing_exempt collective; got #{@collective.tier.inspect}"
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

  test "downgrade: honors return_to=/billing so users stay on the billing page" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade", params: { return_to: "/billing" }

    assert_response :redirect
    assert_equal "/billing", URI(response.location).path,
                 "downgrade with return_to=/billing should redirect back to billing"
  end

  # === Stripe billing-honesty regression tests ===
  #
  # Pre-this-fix, the controller called sync_subscription_quantity! AFTER the
  # tier flip and then unconditionally showed "downgraded to free" — even when
  # the sync failed (or short-circuited on quantity=0, which kept the user on
  # a $3/mo subscription for nothing). Customer-impact: we said the downgrade
  # succeeded but they kept getting billed. The principle these tests pin:
  # NEVER tell the user the downgrade succeeded without verifying the Stripe
  # side actually moved.

  test "downgrade: when this is the user's only paid resource, cancels Stripe subscription so user stops being charged" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(4)}",
      stripe_subscription_id: "sub_downgrade_zero",
      active: true,
    )
    @collective.update!(tier: Collective::TIER_PAID)
    # No other paid resources — post-downgrade billable_quantity will be 0.

    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_downgrade_zero")
      .with(query: hash_including({}))
      .to_return(status: 200,
                 body: { id: "sub_downgrade_zero", object: "subscription", status: "canceled" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade"

    assert_response :redirect
    assert_requested :delete, "https://api.stripe.com/v1/subscriptions/sub_downgrade_zero",
                     query: hash_including({}), at_least_times: 1
    assert_equal Collective::TIER_FREE, @collective.reload.tier
    assert_match(/downgraded/i, flash[:notice].to_s)
  end

  test "downgrade: flash on Stripe sync failure tells the customer when their invoice will reflect the change (no jargon, no support-punt)" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(4)}",
      stripe_subscription_id: "sub_dishonest",
      active: true,
    )
    @collective.update!(tier: Collective::TIER_PAID)
    other = create_test_collective(name: "Other Paid")
    other.update!(tier: Collective::TIER_PAID)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_dishonest")
      .to_return(
        status: 200,
        body: {
          id: "sub_dishonest", object: "subscription", status: "active",
          items: { data: [{ id: "si_dishonest", quantity: 99, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_dishonest")
      .to_return(status: 500, body: { error: { message: "Internal error" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade"

    assert_response :redirect
    assert_match(/24 hours/i, flash[:notice].to_s,
                 "flash must tell the customer when their invoice will reflect the change")
    # No implementation jargon — customers shouldn't see internal terms.
    assert_no_match(/\blocally\b|stripe|billing system/i, flash[:notice].to_s,
                    "flash must not leak internal jargon (\"locally\", \"Stripe\", \"billing system\")")
  end

  test "downgrade: syncs Stripe subscription quantity for the owner so billing drops" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(4)}",
      stripe_subscription_id: "sub_downgrade_sync",
      active: true,
    )
    @collective.update!(tier: Collective::TIER_PAID)
    # Second paid collective so post-downgrade billable_quantity is still > 0
    # (the Stripe SDK skips quantity-zero updates, which would mask whether
    # sync was even called).
    other = create_test_collective(name: "Stays Paid")
    other.update!(tier: Collective::TIER_PAID)

    # Quantity 99 so the sync's "skip if unchanged" short-circuit doesn't fire
    # (post-downgrade billable_quantity will be < 99 → the update call runs).
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_downgrade_sync")
      .to_return(
        status: 200,
        body: {
          id: "sub_downgrade_sync", object: "subscription", status: "active",
          items: { data: [{ id: "si_downgrade_sync", quantity: 99, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_downgrade_sync")
      .to_return(status: 200, body: { id: "si_downgrade_sync", object: "subscription_item" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade"

    assert_response :redirect
    assert_equal Collective::TIER_FREE, @collective.reload.tier
    # downgrade must hit Stripe to update the subscription quantity
    assert_requested :post, "https://api.stripe.com/v1/subscription_items/si_downgrade_sync",
                     at_least_times: 1
  end

  test "archive: redirects to /reverify when 2FA is enabled and not yet reverified" do
    identity = @user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/archive"

    assert_redirected_to "/reverify"
    assert_not @collective.reload.archived?, "collective must not be archived until reverification completes"
  end

  test "archive: owner archives a paid collective; collective is archived, tier drops to free, redirects to settings" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_with_reverification(@user, tenant: @tenant, path: "/collectives/#{@collective.handle}/archive", method: :post)
    post "/collectives/#{@collective.handle}/archive"

    assert_response :redirect
    assert_match(%r{/settings\z}, URI(response.location).path)
    @collective.reload
    assert @collective.archived?, "collective should be archived after reverification + post"
    assert_equal Collective::TIER_FREE, @collective.tier,
                 "archive should auto-downgrade paid → free so unarchive doesn't silently resume billing"
  end

  test "archive: non-owner is rejected with 403 even after reverification" do
    other = create_user
    @tenant.add_user!(other)
    @collective.add_user!(other, roles: ["admin"])

    sign_in_with_reverification(other, tenant: @tenant, path: "/collectives/#{@collective.handle}/archive", method: :post)
    post "/collectives/#{@collective.handle}/archive"

    assert_response :forbidden
    assert_not @collective.reload.archived?
  end

  test "archive: refuses to archive the tenant's main collective" do
    @tenant.update!(main_collective_id: @collective.id)

    sign_in_with_reverification(@user, tenant: @tenant, path: "/collectives/#{@collective.handle}/archive", method: :post)
    post "/collectives/#{@collective.handle}/archive"

    assert_response :redirect
    assert_match(%r{/settings\z}, URI(response.location).path)
    assert_match(/main collective cannot be archived/i, flash[:error].to_s)
    assert_not @collective.reload.archived?
  end

  test "unarchive: redirects to /reverify when 2FA is enabled and not yet reverified" do
    identity = @user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!
    @collective.archive!(actor: @user)

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/unarchive"

    assert_redirected_to "/reverify"
    assert @collective.reload.archived?, "must not unarchive until reverification completes"
  end

  test "unarchive: owner reactivates after reverification; collective is unarchived and stays on free plan" do
    @collective.archive!(actor: @user)
    assert @collective.reload.archived?

    sign_in_with_reverification(@user, tenant: @tenant, path: "/collectives/#{@collective.handle}/unarchive", method: :post)
    post "/collectives/#{@collective.handle}/unarchive"

    assert_response :redirect
    assert_match(%r{/settings\z}, URI(response.location).path)
    @collective.reload
    assert_not @collective.archived?
    assert_equal Collective::TIER_FREE, @collective.tier,
                 "unarchive must not silently resume the paid tier — archive already downgraded"
  end

  test "archive: writes a security audit log entry" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_with_reverification(@user, tenant: @tenant, path: "/collectives/#{@collective.handle}/archive", method: :post)
    recorded = []
    SecurityAuditLog.stub(:log_user_action, ->(**kw) { recorded << kw }) do
      post "/collectives/#{@collective.handle}/archive"
    end

    entry = recorded.find { |r| r[:action] == "collective_archived" }
    assert entry, "expected a collective_archived audit log entry, got: #{recorded.inspect}"
    assert_equal @user, entry[:user]
    assert_equal @collective.id, entry[:details][:collective_id]
    assert_equal @tenant.id, entry[:details][:tenant_id]
  end

  test "unarchive: writes a security audit log entry" do
    @collective.archive!(actor: @user)

    sign_in_with_reverification(@user, tenant: @tenant, path: "/collectives/#{@collective.handle}/unarchive", method: :post)
    recorded = []
    SecurityAuditLog.stub(:log_user_action, ->(**kw) { recorded << kw }) do
      post "/collectives/#{@collective.handle}/unarchive"
    end

    entry = recorded.find { |r| r[:action] == "collective_unarchived" }
    assert entry, "expected a collective_unarchived audit log entry, got: #{recorded.inspect}"
    assert_equal @user, entry[:user]
    assert_equal @collective.id, entry[:details][:collective_id]
  end

  test "unarchive: non-owner is rejected with 403 even after reverification" do
    other = create_user
    @tenant.add_user!(other)
    @collective.add_user!(other, roles: ["admin"])
    @collective.archive!(actor: @user)

    sign_in_with_reverification(other, tenant: @tenant, path: "/collectives/#{@collective.handle}/unarchive", method: :post)
    post "/collectives/#{@collective.handle}/unarchive"

    assert_response :forbidden
    assert @collective.reload.archived?
  end

  test "downgrade: ignores untrusted return_to values (open redirect guard)" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    @collective.update!(tier: Collective::TIER_PAID)
    stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/.*})
      .to_return(status: 200, body: { id: "sub_x", status: "active", items: { data: [] } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/downgrade", params: { return_to: "https://evil.example.com/phish" }

    assert_response :redirect
    redirect_path = URI(response.location).path
    assert_not_equal "/phish", redirect_path
    assert_match(%r{/settings\z}, redirect_path,
                 "untrusted return_to must fall through to the default settings redirect")
  end

  # === Member Management Tests (issue #316) ===
  #
  # Member management runs through the standard action pipeline:
  #   POST /collectives/:handle/members/actions/{update_member_roles,remove_member}
  # The markdown (action API) contract returns real HTTP status codes, so the
  # behavioral tests drive the endpoints with an `Accept: text/markdown` header.

  MEMBER_MGMT_MD = { "Accept" => "text/markdown" }.freeze

  def add_member(name:, roles: [])
    user = create_user(name: name)
    @tenant.add_user!(user)
    @collective.add_user!(user, roles: roles)
    user
  end

  # The member-management actions identify their target by handle (the id the
  # markdown/agent interface exposes), not the internal numeric user id.
  def handle_for(user)
    user.tenant_users.find_by(tenant_id: @tenant.id).handle
  end

  def update_roles_path(collective = @collective)
    "/collectives/#{collective.handle}/members/actions/update_member_roles"
  end

  def remove_member_path(collective = @collective)
    "/collectives/#{collective.handle}/members/actions/remove_member"
  end

  # Mint a write-scoped API token for an agent — agents authenticate via Bearer
  # token, not browser sessions (those are redirected), so the elevation-of-
  # privilege tests below drive the action endpoints the way an agent actually
  # would.
  def agent_api_token(agent)
    # Bearer-token auth is gated on the tenant (and the collective) having API
    # access enabled — otherwise the request is rejected with a 403 "API not
    # enabled for this tenant" before it ever reaches the action.
    @tenant.enable_api!
    @collective.enable_api!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes)
  ensure
    Tenant.clear_thread_scope
  end

  def agent_md_headers(agent)
    { "Authorization" => "Bearer #{agent_api_token(agent).plaintext_token}", "Accept" => "text/markdown" }
  end

  test "members page shows management controls for admins" do
    add_member(name: "Regular Member")
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success
    # Admins get a per-member kebab menu whose items POST to the action endpoints.
    assert_select "details.pulse-member-menu", minimum: 1
    assert_select "form.pulse-member-menu-form[action$=?]", "/members/actions/update_member_roles", minimum: 1
  end

  test "members page hides management controls from non-admins" do
    member = add_member(name: "Regular Member")
    sign_in_as(member, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success
    # No kebab menu and no action forms for non-admins.
    assert_select "details.pulse-member-menu", count: 0
    assert_select "form.pulse-member-menu-form", count: 0
  end

  test "admin can grant a role to a member" do
    member = add_member(name: "Future Rep")
    sign_in_as(@user, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(member), role: "representative", grant: "true" },
         headers: MEMBER_MGMT_MD

    assert_response :success
    cm = @collective.collective_members.find_by(user: member)
    assert cm.has_role?("representative"), "expected the representative role to be granted"
  end

  test "admin can revoke a role from a member" do
    member = add_member(name: "Demoted Rep", roles: ["representative"])
    sign_in_as(@user, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(member), role: "representative", grant: "false" },
         headers: MEMBER_MGMT_MD

    assert_response :success
    cm = @collective.collective_members.find_by(user: member)
    assert_not cm.has_role?("representative"), "expected the representative role to be revoked"
  end

  test "persona roles cannot be granted through the role endpoint" do
    member = add_member(name: "Would-be Cadence")
    sign_in_as(@user, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(member), role: "cadence", grant: "true" },
         headers: MEMBER_MGMT_MD

    assert_response :unprocessable_entity
    cm = @collective.collective_members.find_by(user: member)
    assert_not cm.has_role?("cadence"), "persona roles are activator-managed, never grantable"
  end

  test "the members page role menu offers only capability roles" do
    add_member(name: "Regular Member")
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success
    assert_no_match(/role cadence/, response.body)
  end

  test "non-admin cannot update member roles" do
    actor = add_member(name: "Not An Admin")
    target = add_member(name: "Target")
    sign_in_as(actor, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(target), role: "representative", grant: "true" },
         headers: MEMBER_MGMT_MD

    assert_response :forbidden
    cm = @collective.collective_members.find_by(user: target)
    assert_not cm.has_role?("representative")
  end

  test "rejects an invalid role" do
    member = add_member(name: "Member")
    sign_in_as(@user, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(member), role: "superuser", grant: "true" },
         headers: MEMBER_MGMT_MD

    assert_response :unprocessable_entity
  end

  test "cannot remove the admin role from the last admin" do
    # @user is the only admin of @collective (set in setup).
    sign_in_as(@user, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(@user), role: "admin", grant: "false" },
         headers: MEMBER_MGMT_MD

    assert_response :unprocessable_entity
    cm = @collective.collective_members.find_by(user: @user)
    assert cm.has_role?("admin"), "the last admin must retain the admin role"
  end

  test "cannot revoke the admin role from the collective owner" do
    # A second admin exists, so this is blocked by the owner guard rather than
    # the last-admin guard.
    other_admin = add_member(name: "Second Admin", roles: ["admin"])
    sign_in_as(other_admin, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(@user), role: "admin", grant: "false" },
         headers: MEMBER_MGMT_MD

    assert_response :unprocessable_entity
    cm = @collective.collective_members.find_by(user: @user)
    assert cm.has_role?("admin"), "the collective owner must remain an admin"
  end

  test "members page shows the owner admin as a pill, not a role toggle" do
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success
    # The owner's admin surfaces as a (non-revocable) pill…
    assert_select "[data-role-pills-for=?] span[data-role-pill=?]", @user.id.to_s, "admin"
    # …and is never rendered as a revocable role-toggle form.
    assert_select "form.pulse-member-menu-form[data-member-id=?][data-role=?]", @user.id.to_s, "admin", count: 0
  end

  test "members page renders a per-member kebab menu with add-role and remove items" do
    member = add_member(name: "Regular Member")
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success

    # Each manageable member gets a kebab <details> menu for adding/removing
    # roles (the role pills themselves are covered separately below).
    assert_select "details.pulse-member-menu", minimum: 1
    # A role the member lacks is offered as an "Add role" action whose form
    # carries grant=true so the click adds the role.
    assert_select "form.pulse-member-menu-form[data-member-id=?][data-role=?]", member.id.to_s, "representative" do
      assert_select "input[name=?][value=?]", "grant", "true"
    end
    assert_match(/Add role representative/, response.body)
    # …and the destructive action posts to the remove endpoint at the bottom.
    assert_select "form.pulse-member-menu-form[action$=?] button.pulse-member-menu-item-danger",
                  "/members/actions/remove_member"
    assert_match(/Remove from collective/, response.body)
  end

  test "members page renders role pills for the roles a member holds" do
    member = add_member(name: "Sitting Rep", roles: ["representative"])
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success

    # The pill row shows the roles the member currently holds, so admins can see
    # who has which roles at a glance.
    assert_select "[data-role-pills-for=?] span[data-role-pill=?]", member.id.to_s, "representative"
    # A role the member does not hold gets no pill.
    assert_select "[data-role-pills-for=?] span[data-role-pill=?]", member.id.to_s, "summarizer", count: 0
  end

  test "members page renders the owner's admin as a pill" do
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success

    # The owner always holds admin; it surfaces as a (non-revocable) pill.
    assert_select "[data-role-pills-for=?] span[data-role-pill=?]", @user.id.to_s, "admin"
  end

  test "members page shows an already-held role as a 'Remove role' menu item" do
    member = add_member(name: "Sitting Rep", roles: ["representative"])
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success

    # A held role's form carries grant=false so the click revokes it.
    assert_select "form.pulse-member-menu-form[data-member-id=?][data-role=?]", member.id.to_s, "representative" do
      assert_select "input[name=?][value=?]", "grant", "false"
    end
    assert_match(/Remove role representative/, response.body)
  end

  test "members page does not offer a remove-from-collective item for the acting admin" do
    # A second admin manages the page; they must not see a self-removal control
    # (Leave handles that), though they can still toggle their own roles.
    other_admin = add_member(name: "Second Admin", roles: ["admin"])
    sign_in_as(other_admin, tenant: @tenant)

    get "/collectives/#{@collective.handle}/members"
    assert_response :success

    # No remove form targeting the acting admin themselves.
    assert_select "form.pulse-member-menu-form[action$=?] input[name=?][value=?]",
                  "/members/actions/remove_member", "user_handle", handle_for(other_admin), count: 0
  end

  test "admin can revoke admin role when another admin remains" do
    other_admin = add_member(name: "Second Admin", roles: ["admin"])
    sign_in_as(@user, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(other_admin), role: "admin", grant: "false" },
         headers: MEMBER_MGMT_MD

    assert_response :success
    cm = @collective.collective_members.find_by(user: other_admin)
    assert_not cm.has_role?("admin")
  end

  test "admin can remove a member from the collective" do
    member = add_member(name: "Leaving Member")
    sign_in_as(@user, tenant: @tenant)

    post remove_member_path,
         params: { user_handle: handle_for(member) },
         headers: MEMBER_MGMT_MD

    assert_response :success
    cm = @collective.collective_members.find_by(user: member)
    assert cm.archived?, "expected the membership to be archived"
  end

  test "cannot remove the collective owner" do
    other_admin = add_member(name: "Second Admin", roles: ["admin"])
    sign_in_as(other_admin, tenant: @tenant)

    post remove_member_path,
         params: { user_handle: handle_for(@user) },
         headers: MEMBER_MGMT_MD

    assert_response :unprocessable_entity
    cm = @collective.collective_members.find_by(user: @user)
    assert_not cm.archived?, "the owner must not be removable"
  end

  test "admin cannot remove themselves via the member management UI" do
    other_admin = add_member(name: "Second Admin", roles: ["admin"])
    sign_in_as(other_admin, tenant: @tenant)

    post remove_member_path,
         params: { user_handle: handle_for(other_admin) },
         headers: MEMBER_MGMT_MD

    assert_response :unprocessable_entity
    cm = @collective.collective_members.find_by(user: other_admin)
    assert_not cm.archived?, "self-removal must be blocked"
  end

  test "non-admin cannot remove a member" do
    actor = add_member(name: "Not An Admin")
    target = add_member(name: "Target")
    sign_in_as(actor, tenant: @tenant)

    post remove_member_path,
         params: { user_handle: handle_for(target) },
         headers: MEMBER_MGMT_MD

    assert_response :forbidden
    cm = @collective.collective_members.find_by(user: target)
    assert_not cm.archived?
  end

  test "removing a non-member returns 404" do
    stranger = create_user(name: "Stranger")
    @tenant.add_user!(stranger)
    sign_in_as(@user, tenant: @tenant)

    post remove_member_path,
         params: { user_handle: handle_for(stranger) },
         headers: MEMBER_MGMT_MD

    assert_response :not_found
  end

  test "a non-member of the collective cannot update member roles" do
    # The actor belongs to the tenant but is NOT a member of @collective. A
    # non-member is stopped at the collective-membership boundary itself: the
    # request is bounced to the collective's /join page before it ever reaches
    # the member-management authz. That redirect *is* the denial — the mutation
    # never runs — which is a strictly stronger guarantee than a 403 from the
    # action.
    outsider = create_user(name: "Tenant Outsider")
    @tenant.add_user!(outsider)
    target = add_member(name: "Target")
    sign_in_as(outsider, tenant: @tenant)

    post update_roles_path,
         params: { user_handle: handle_for(target), role: "representative", grant: "true" },
         headers: MEMBER_MGMT_MD

    assert_redirected_to "#{@collective.path}/join"
    cm = @collective.collective_members.find_by(user: target)
    assert_not cm.has_role?("representative"), "a non-member must not be able to grant roles"
  end

  test "a non-member of the collective cannot remove a member" do
    # As above: a non-member is bounced to /join at the collective boundary
    # before reaching the action, so the removal never runs.
    outsider = create_user(name: "Tenant Outsider")
    @tenant.add_user!(outsider)
    target = add_member(name: "Target")
    sign_in_as(outsider, tenant: @tenant)

    post remove_member_path,
         params: { user_handle: handle_for(target) },
         headers: MEMBER_MGMT_MD

    assert_redirected_to "#{@collective.path}/join"
    cm = @collective.collective_members.find_by(user: target)
    assert_not cm.archived?, "a non-member must not be able to remove members"
  end

  test "member roles cannot be managed on a private workspace even by its admin" do
    # Every user is the admin of their own private workspace, so this passes the
    # admin check and exercises the collective-type guard specifically: member
    # management is forbidden on private workspaces (and the main collective).
    sign_in_as(@user, tenant: @tenant)
    workspace = Collective.unscoped.find_by(
      tenant_id: @tenant.id,
      created_by_id: @user.id,
      collective_type: "private_workspace",
    )
    assert_not_nil workspace, "expected @user to own a private workspace"

    post update_roles_path(workspace),
         params: { user_handle: handle_for(@user), role: "representative", grant: "true" },
         headers: MEMBER_MGMT_MD

    assert_response :forbidden
    assert_match(/cannot be managed/i, response.body)
  end

  test "members cannot be removed from a private workspace even by its admin" do
    sign_in_as(@user, tenant: @tenant)
    workspace = Collective.unscoped.find_by(
      tenant_id: @tenant.id,
      created_by_id: @user.id,
      collective_type: "private_workspace",
    )
    assert_not_nil workspace, "expected @user to own a private workspace"

    post remove_member_path(workspace),
         params: { user_handle: handle_for(@user) },
         headers: MEMBER_MGMT_MD

    assert_response :forbidden
    assert_match(/cannot be managed/i, response.body)
  end

  test "the describe endpoint documents the update_member_roles params" do
    sign_in_as(@user, tenant: @tenant)

    get update_roles_path, headers: MEMBER_MGMT_MD

    assert_response :success
    assert_match(/update_member_roles/, response.body)
    assert_match(/user_handle/, response.body)
    assert_match(/role/, response.body)
    assert_match(/grant/, response.body)
  end

  # Member management is a two-key elevation-of-privilege surface for AI agents:
  # the agent needs BOTH the owner-granted capability (here: default config, so
  # all grantable actions are allowed) AND collective-admin standing. An agent
  # that a human has deliberately made a collective admin can act.
  test "an AI-agent admin with the capability can update member roles" do
    agent = create_ai_agent(parent: @user, name: "Admin Bot", agent_configuration: { "mode" => "external" })
    @collective.add_user!(agent, roles: ["admin"])
    target = add_member(name: "Target")

    post update_roles_path,
         params: { user_handle: handle_for(target), role: "representative", grant: "true" },
         headers: agent_md_headers(agent)

    assert_response :success
    cm = @collective.collective_members.find_by(user: target)
    assert cm.has_role?("representative"), "an admin AI agent with the capability should grant the role"
  end

  test "an AI-agent admin with the capability can remove members" do
    agent = create_ai_agent(parent: @user, name: "Admin Bot", agent_configuration: { "mode" => "external" })
    @collective.add_user!(agent, roles: ["admin"])
    target = add_member(name: "Target")

    post remove_member_path,
         params: { user_handle: handle_for(target) },
         headers: agent_md_headers(agent)

    assert_response :success
    cm = @collective.collective_members.find_by(user: target)
    assert cm.archived?, "an admin AI agent with the capability should remove the member"
  end

  # First key: the owner-granted capability. An agent whose capabilities are
  # narrowed to exclude member management is denied by the capability layer even
  # if it is a collective admin.
  test "an AI-agent admin without the member-management capability is denied" do
    agent = create_ai_agent(
      parent: @user, name: "Scoped Bot",
      agent_configuration: { "mode" => "external", "capabilities" => ["create_note"] },
    )
    @collective.add_user!(agent, roles: ["admin"])
    target = add_member(name: "Target")

    post update_roles_path,
         params: { user_handle: handle_for(target), role: "representative", grant: "true" },
         headers: agent_md_headers(agent)

    assert_response :forbidden
    cm = @collective.collective_members.find_by(user: target)
    assert_not cm.has_role?("representative"), "an agent lacking the capability must not grant roles"
  end

  # Second key: collective-admin standing. An agent with the capability but no
  # admin role is rejected by the action's :collective_admin authorization.
  test "an AI-agent non-admin with the capability is denied by authorization" do
    agent = create_ai_agent(parent: @user, name: "Member Bot", agent_configuration: { "mode" => "external" })
    @collective.add_user!(agent) # no admin role
    target = add_member(name: "Target")

    post update_roles_path,
         params: { user_handle: handle_for(target), role: "representative", grant: "true" },
         headers: agent_md_headers(agent)

    assert_response :forbidden
    cm = @collective.collective_members.find_by(user: target)
    assert_not cm.has_role?("representative"), "a non-admin agent must not grant roles"
  end

  # === Funding pools ===

  def fund_user!(user, stripe_id: "cus_#{SecureRandom.hex(6)}")
    StripeCustomer.create!(
      billable: user, stripe_id: stripe_id, active: true, pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}"
    )
  end

  def enable_funding_pools!(collective)
    enable_stripe_billing_flag!(@tenant)
    FeatureFlagService.config["funding_pools"] ||= {}
    FeatureFlagService.config["funding_pools"]["app_enabled"] = true
    @tenant.enable_feature_flag!("funding_pools")
    collective.enable_feature_flag!("funding_pools")
  end

  def create_pool!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    FundingPool.create!(tenant: @tenant, collective: collective, created_by: @user, member_draw_cap_cents: 500)
  ensure
    Tenant.clear_thread_scope
  end

  def add_member!(collective, user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.add_user!(user)
  ensure
    Tenant.clear_thread_scope
  end

  def enroll!(pool, user, draw_cap_cents: 500)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    pool.enroll!(user, draw_cap_cents: draw_cap_cents)
  ensure
    Tenant.clear_thread_scope
  end

  def active_enrollment?(pool, user)
    FundingPoolEnrollment.tenant_scoped_only(@tenant.id).where(archived_at: nil)
      .exists?(funding_pool_id: pool.id, user_id: user.id)
  end

  test "an admin can create a funding pool with an explicit draw ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

    assert_redirected_to "#{collective.path}/settings"
    pool = FundingPool.tenant_scoped_only(@tenant.id).find_by(collective_id: collective.id)
    assert pool.present?
    assert_equal 500, pool.member_draw_cap_cents
  end

  test "an admin can open a pool with a weekly ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool",
         params: { member_daily_draw_cap: "5.00", member_draw_cap_period: "week" }

    assert_redirected_to "#{collective.path}/settings"
    pool = FundingPool.tenant_scoped_only(@tenant.id).find_by(collective_id: collective.id)
    assert pool.present?
    assert_equal 500, pool.member_draw_cap_cents
    assert_equal "week", pool.member_draw_cap_period
  end

  test "opening a pool with an invalid ceiling window is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool",
         params: { member_daily_draw_cap: "5.00", member_draw_cap_period: "fortnight" }

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "creating a pool without a draw ceiling is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool"

    assert flash[:alert].present?, "expected a friendly refusal — every pool needs an explicit ceiling"
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)

    post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "not money" }

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "non-admin members cannot create a funding pool" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool"

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  # Self-serve availability: paid tier + tenant-level flag, no collective flag.
  def enable_self_serve_pools!(collective)
    enable_stripe_billing_flag!(@tenant)
    FeatureFlagService.config["funding_pools"] ||= {}
    FeatureFlagService.config["funding_pools"]["app_enabled"] = true
    @tenant.enable_feature_flag!("funding_pools")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    upgrade_collective_to_paid!(collective)
  ensure
    Tenant.clear_thread_scope
  end

  test "a paid-tier collective admin can open a pool self-serve without the operator flag" do
    collective = create_test_collective
    enable_self_serve_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

    assert_redirected_to "#{collective.path}/settings"
    assert FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "a free-tier collective cannot open a pool without the operator flag" do
    collective = create_test_collective
    enable_stripe_billing_flag!(@tenant)
    FeatureFlagService.config["funding_pools"] ||= {}
    FeatureFlagService.config["funding_pools"]["app_enabled"] = true
    @tenant.enable_feature_flag!("funding_pools")
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "members can enroll in a self-serve pool" do
    collective = create_test_collective
    enable_self_serve_pools!(collective)
    pool = create_pool!(collective)
    member = create_user(name: "Enrollee")
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { ceiling_choice: "pool" }

    assert active_enrollment?(pool, member), "expected enrollment on a self-serve pool to succeed"
  end

  test "attaching an agent to a self-serve pool still requires the operator flag" do
    collective = create_test_collective
    enable_self_serve_pools!(collective)
    pool = create_pool!(collective)
    # upgrade_collective_to_paid! already gave the owner a StripeCustomer;
    # enrollment additionally needs funded (prepaid-credit) billing.
    @user.reload.stripe_customer.update!(pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}")
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }

    assert flash[:alert].present?, "expected non-persona agent attach to stay operator-gated"
    assert_nil agent.reload.funding_pool_id
  end

  test "opening a pool automatically funds the collective's personas" do
    collective = create_test_collective
    enable_self_serve_pools!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    trio = T.must(PersonaActivator.activate!(collective).find { |a| a.system_role == "cadence" })
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

    pool = FundingPool.tenant_scoped_only(@tenant.id).find_by(collective_id: collective.id)
    assert pool.present?
    assert_equal pool.id, trio.reload.funding_pool_id, "expected the persona to be auto-attached to the new pool"
  end

  test "a persona cannot be detached from the pool" do
    collective = create_test_collective
    enable_self_serve_pools!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    trio = T.must(PersonaActivator.activate!(collective).find { |a| a.system_role == "cadence" })
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)
    post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "5.00" }
    pool = FundingPool.tenant_scoped_only(@tenant.id).find_by(collective_id: collective.id)
    assert_equal pool.id, trio.reload.funding_pool_id

    delete "#{collective.path}/settings/remove_funded_agent", params: { ai_agent_id: trio.id }

    assert flash[:alert].present?, "expected detaching the persona to be refused"
    assert_equal pool.id, trio.reload.funding_pool_id, "the persona must stay on the pool payroll"
  end

  test "creating a pool requires the stripe_billing feature" do
    collective = create_test_collective
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool"

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "a pool cannot be opened on an archived collective" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.update!(archived_at: Time.current, archived_by_id: @user.id)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool"

    # The global archived-collective interceptor bounces the request to the
    # settings page before the action runs; the pool must not be created.
    assert_redirected_to "#{collective.path}/settings"
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "a pool cannot be opened on a non-standard collective" do
    enable_stripe_billing_flag!(@tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    chat = Collective.create!(
      tenant: @tenant, created_by: @user, name: "Chat", handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat"
    )
    cm = chat.add_user!(@user)
    cm.add_role!("admin")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    enable_funding_pools!(chat)
    sign_in_as(@user, tenant: @tenant)

    post "#{chat.path}/settings/create_funding_pool"

    assert_response :redirect
    assert flash[:alert].present?, "expected a friendly refusal, not a crash"
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: chat.id)
  end

  test "creating the pool again reopens a closed pool instead of failing" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_period: "week")
    pool.archive!
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool"

    assert_redirected_to "#{collective.path}/settings"
    pool.reload
    assert_not pool.archived?, "expected the closed pool to reopen"
    assert_equal 500, pool.member_draw_cap_cents, "reopening without a ceiling param keeps the existing ceiling"
    assert_equal "week", pool.member_draw_cap_period, "reopening without a period param keeps the existing window"
  end

  test "reopening a closed pool with a ceiling param updates the ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.archive!
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "2.50" }

    pool.reload
    assert_not pool.archived?
    assert_equal 250, pool.member_draw_cap_cents
  end

  test "an admin can close the pool" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/close_funding_pool"

    assert_redirected_to "#{collective.path}/settings"
    assert pool.reload.archived?
  end

  test "non-admins cannot close the pool" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/settings/close_funding_pool"

    assert flash[:alert].present?
    assert_not pool.reload.archived?
  end

  test "a funded member can enroll themselves with their own ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { daily_draw_cap: "3.00" }

    assert_redirected_to "#{collective.path}/pool"
    assert active_enrollment?(pool, @user)
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 300, enrollment.draw_cap_cents
    assert_equal "day", enrollment.draw_cap_period, "omitting the period defaults the ceiling window to a day"
  end

  test "a custom enrollment without a period param defaults its window to a day" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool",
         params: { ceiling_choice: "custom", daily_draw_cap: "3.00" }

    assert_redirected_to "#{collective.path}/pool"
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 300, enrollment.draw_cap_cents
    assert_equal "day", enrollment.draw_cap_period, "omitting the period defaults the ceiling window to a day"
  end

  test "enrolling without a ceiling is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool"

    assert_redirected_to "#{collective.path}/pool"
    assert_match(/ceiling/i, flash[:alert], "consent must state an explicit ceiling")
    assert_not active_enrollment?(pool, @user)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { daily_draw_cap: "several" }

    assert flash[:alert].present?
    assert_not active_enrollment?(pool, @user)
  end

  test "enrolling with the pool-ceiling choice adopts the pool's current ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { ceiling_choice: "pool" }

    assert_redirected_to "#{collective.path}/pool"
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 500, enrollment.draw_cap_cents, "the pool choice snapshots the pool's ceiling as the member's own"
  end

  test "enrolling with the custom choice but no amount is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { ceiling_choice: "custom" }

    assert_redirected_to "#{collective.path}/pool"
    assert_match(/ceiling/i, flash[:alert])
    assert_not active_enrollment?(pool, @user)
  end

  test "the enroll form offers the pool ceiling as the default with a custom opt-down" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_match(/Match the pool ceiling/i, response.body)
    assert_match(/ceiling_choice/, response.body)
  end

  test "an enrolled member can update their ceiling by re-enrolling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { daily_draw_cap: "1.25" }

    assert_redirected_to "#{collective.path}/pool"
    assert active_enrollment?(pool, @user)
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 125, enrollment.draw_cap_cents
  end

  test "enrolling without funded billing fails with a friendly error" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { daily_draw_cap: "3.00" }

    assert_redirected_to "#{collective.path}/pool"
    assert_match(/billing/i, flash[:alert])
    assert_not active_enrollment?(pool, @user)
  end

  test "an enrolled member can withdraw" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    sign_in_as(@user, tenant: @tenant)

    delete "#{collective.path}/settings/withdraw_from_funding_pool"

    assert_redirected_to "#{collective.path}/pool"
    assert_not active_enrollment?(pool, @user)
    assert_no_match(/stay attached/, flash[:notice], "no agent warning when the member has no attached agents")
  end

  test "withdrawing with attached agents says they stay attached but stop" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    delete "#{collective.path}/settings/withdraw_from_funding_pool"

    assert_match(/stay attached/, flash[:notice])
    assert_match(/calls are refused/, flash[:notice])
  end

  test "enrolling above the pool ceiling notes that the pool ceiling applies" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { daily_draw_cap: "50.00" }

    assert active_enrollment?(pool, @user)
    assert_match(/pool's \$5\.00 ceiling applies/, flash[:notice])
  end

  test "a funded member can enroll with a weekly ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool",
         params: { ceiling_choice: "custom", daily_draw_cap: "3.00", draw_cap_period: "week" }

    assert_redirected_to "#{collective.path}/pool"
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 300, enrollment.draw_cap_cents
    assert_equal "week", enrollment.draw_cap_period
    assert_match(/pool's \$5\.00 per day ceiling also applies/, flash[:notice],
                 "ceilings over different windows both apply — the flash must not claim one is lower")
  end

  test "the pool-ceiling choice adopts the pool's period, ignoring any submitted period" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    pool.update!(member_draw_cap_period: "week")
    Tenant.clear_thread_scope
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool",
         params: { ceiling_choice: "pool", draw_cap_period: "month" }

    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 500, enrollment.draw_cap_cents
    assert_equal "week", enrollment.draw_cap_period, "the pool choice snapshots the pool's period, not the submitted one"
  end

  test "enrolling with an invalid period is refused without touching the enrollment" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool",
         params: { ceiling_choice: "custom", daily_draw_cap: "3.00", draw_cap_period: "fortnight" }

    assert_redirected_to "#{collective.path}/pool"
    assert flash[:alert].present?
    assert_not active_enrollment?(pool, @user)
  end

  test "re-enrolling can change only the period, keeping the same ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user, draw_cap_cents: 300)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool",
         params: { ceiling_choice: "custom", daily_draw_cap: "3.00", draw_cap_period: "month" }

    assert_redirected_to "#{collective.path}/pool"
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 300, enrollment.draw_cap_cents
    assert_equal "month", enrollment.draw_cap_period
  end

  test "the pool page offers a draw-cap period selector" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "select[name=?]", "draw_cap_period" do
      assert_select "option[value=?]", "day"
      assert_select "option[value=?]", "week"
      assert_select "option[value=?]", "month"
    end
  end

  test "the settings page shows funding consent copy pointing members at the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings"

    assert_response :success
    assert_match(/consenting to fund/i, response.body)
    assert_match(/prepaid balance/i, response.body)
  end

  test "an admin can attach an enrolled member's agent" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }

    assert_response :redirect
    assert_equal pool.id, agent.reload.funding_pool_id
  end

  test "non-admin members cannot attach agents" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    enroll!(pool, member)
    agent = create_ai_agent(parent: member)
    @tenant.add_user!(agent)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/settings"
    assert flash[:alert].present?, "expected an alert explaining the refusal"
    assert_nil agent.reload.funding_pool_id
  end

  test "attach errors are JSON for JSON requests" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    enroll!(pool, member)
    agent = create_ai_agent(parent: member)
    @tenant.add_user!(agent)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }, as: :json

    assert_response :forbidden
    assert response.parsed_body["error"].present?
    assert_nil agent.reload.funding_pool_id
  end

  test "attach is refused when the collective has no pool" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    fund_user!(@user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/settings"
    assert flash[:alert].present?
    assert_nil agent.reload.funding_pool_id
  end

  test "attach fails clearly when the agent's principal is not enrolled" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    outsider = create_user(name: "Outsider")
    @tenant.add_user!(outsider)
    agent = create_ai_agent(parent: outsider)
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/settings"
    assert_match(/enrolled/i, flash[:alert])
    assert_nil agent.reload.funding_pool_id
  end

  test "an agent from another tenant cannot be attached" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    other_tenant = create_tenant(subdomain: "other-fund-#{SecureRandom.hex(4)}")
    other_tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }, as: :json

    assert_response :not_found
    assert_nil agent.reload.funding_pool_id
  end

  test "the attach list only offers this tenant's agents of enrolled members" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    local = create_ai_agent(parent: @user, name: "Local Fund Bot")
    @tenant.add_user!(local)
    foreign = create_ai_agent(parent: @user, name: "Foreign Fund Bot")
    other_tenant = create_tenant(subdomain: "other-fund-#{SecureRandom.hex(4)}")
    other_tenant.add_user!(foreign)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings"

    assert_response :success
    assert_match "Local Fund Bot", response.body
    assert_no_match(/Foreign Fund Bot/, response.body)
  end

  test "an admin can set and clear the member daily draw ceiling without touching other settings" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    original_name = collective.name
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.settings["all_members_can_invite"] = true
    collective.save!
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    referer = { "Referer" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}#{collective.path}/settings" }

    # The ceiling lives in its own small form inside the pool section, so it
    # posts alone — a cap-only POST must not clobber the fields the main
    # settings form would have carried.
    post "#{collective.path}/settings", params: { member_daily_draw_cap: "0.50" }, headers: referer
    assert_equal 50, pool.reload.member_draw_cap_cents
    collective.reload
    assert_equal original_name, collective.name, "a cap-only POST must not blank the name"
    assert collective.all_members_can_invite?, "a cap-only POST must not reset the invitation policy"

    # The ceiling is mandatory: a blank submission is a rejected attempt to
    # clear it, not a way to lift the limit.
    post "#{collective.path}/settings", params: { member_daily_draw_cap: "" }, headers: referer
    assert flash[:error].present?, "clearing the ceiling must be refused"
    assert_equal 50, pool.reload.member_draw_cap_cents
  end

  test "the ceiling form can change the pool's ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    referer = { "Referer" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}#{collective.path}/settings" }

    post "#{collective.path}/settings", params: { member_daily_draw_cap: "0.50", member_draw_cap_period: "week" }, headers: referer

    pool.reload
    assert_equal 50, pool.member_draw_cap_cents
    assert_equal "week", pool.member_draw_cap_period
  end

  test "an invalid ceiling window on the settings form is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    referer = { "Referer" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}#{collective.path}/settings" }

    post "#{collective.path}/settings", params: { member_daily_draw_cap: "0.50", member_draw_cap_period: "fortnight" }, headers: referer

    assert flash[:error].present?
    pool.reload
    assert_equal 500, pool.member_draw_cap_cents, "an invalid window must not change the ceiling"
    assert_equal "day", pool.member_draw_cap_period
  end

  test "the settings page offers a pool ceiling window selector" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings"

    assert_response :success
    assert_select "select[name=?]", "member_draw_cap_period" do
      assert_select "option[value=?]", "day"
      assert_select "option[value=?]", "week"
      assert_select "option[value=?]", "month"
    end

    create_pool!(collective)
    get "#{collective.path}/settings"

    assert_response :success
    assert_select "select[name=?]", "member_draw_cap_period"
  end

  test "an over-large draw ceiling is rejected with a friendly error" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 50)
    sign_in_as(@user, tenant: @tenant)
    referer = { "Referer" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}#{collective.path}/settings" }

    post "#{collective.path}/settings", params: { member_daily_draw_cap: "30000000" }, headers: referer

    assert_response :redirect
    assert flash[:error].present?
    assert_equal 50, pool.reload.member_draw_cap_cents
  end

  test "the update_collective_settings action sets the draw ceiling but refuses to clear it" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "0.75" }.to_json, headers: headers
    assert_response :success
    assert_equal 75, pool.reload.member_draw_cap_cents

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "" }.to_json, headers: headers
    assert_response :unprocessable_entity
    assert_equal 75, pool.reload.member_draw_cap_cents, "the ceiling is mandatory and cannot be cleared"
  end

  test "the update_collective_settings action can set the ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "0.75", member_draw_cap_period: "month" }.to_json, headers: headers

    assert_response :success
    pool.reload
    assert_equal 75, pool.member_draw_cap_cents
    assert_equal "month", pool.member_draw_cap_period
  end

  test "the update_collective_settings action refuses a period change without a ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_draw_cap_period: "week" }.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_match(/member_daily_draw_cap/, response.body)
    assert_equal "day", pool.reload.member_draw_cap_period, "a period-only change must not silently take effect"
  end

  test "the update_collective_settings action refuses an invalid ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "0.75", member_draw_cap_period: "fortnight" }.to_json, headers: headers

    assert_response :unprocessable_entity
    pool.reload
    assert_equal 500, pool.member_draw_cap_cents, "an invalid window must not change the ceiling"
    assert_equal "day", pool.member_draw_cap_period
  end

  test "the update_collective_settings action rejects a bad draw ceiling with a friendly message" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 50)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "lots" }.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_no_match(/BigDecimal/, response.body, "internal parse errors must not leak to the action API")
    assert_equal 50, pool.reload.member_draw_cap_cents
  end

  test "the draw ceiling action is refused while the flag is off" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 50)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "0.75" }.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_match(/not enabled/i, response.body)
    assert_equal 50, pool.reload.member_draw_cap_cents
  end

  test "the markdown settings page notes the wind-down state when the flag is off" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/not available for this collective/i, response.body)
  end

  test "setting a draw ceiling on a collective without a pool fails with a friendly message" do
    collective = create_test_collective
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "0.75" }.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_match(/funding pool/i, response.body)
  end

  test "detaching an agent not funded by this pool redirects with an alert" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    fund_user!(@user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)

    delete "#{collective.path}/settings/remove_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/settings"
    assert flash[:alert].present?
  end

  test "an admin can detach a funded agent" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    delete "#{collective.path}/settings/remove_funded_agent", params: { ai_agent_id: agent.id }

    assert_response :redirect
    assert_nil agent.reload.funding_pool_id
  end

  test "creating a pool requires the funding_pools flag" do
    enable_stripe_billing_flag!(@tenant)
    collective = create_test_collective
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/create_funding_pool"

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "collective admins cannot self-enable the funding_pools flag" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)
    referer = { "Referer" => "http://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}#{collective.path}/settings" }

    post "#{collective.path}/settings", params: { name: collective.name, feature_funding_pools: "true" }, headers: referer

    assert_not collective.reload.feature_flag_enabled_locally?("funding_pools"),
               "operator-managed flags must not be self-serve from collective settings"
  end

  test "enrolling requires the funding_pools flag" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/enroll_in_funding_pool"

    assert flash[:alert].present?
    assert_not active_enrollment?(pool, @user)
  end

  test "attaching requires the funding_pools flag" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/add_funded_agent", params: { ai_agent_id: agent.id }

    assert flash[:alert].present?
    assert_nil agent.reload.funding_pool_id
  end

  test "withdraw and detach still work after the flag is disabled" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    delete "#{collective.path}/settings/withdraw_from_funding_pool"
    assert_not active_enrollment?(pool, @user), "withdrawal is a consent exit and must never be flag-gated"

    delete "#{collective.path}/settings/remove_funded_agent", params: { ai_agent_id: agent.id }
    assert_nil agent.reload.funding_pool_id, "detach stops spending and must never be flag-gated"
  end

  test "the agents section does not reference the pool section when it is hidden" do
    collective = create_test_collective
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @tenant.enable_feature_flag!("api")
    collective.enable_feature_flag!("api")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings"

    assert_response :success
    assert_match(/AI Agents in this Collective/, response.body, "the agents section itself should render")
    assert_no_match(/Agent Funding Pool\s+section above/, response.body,
                    "must not point at a section that is not rendered")
  end

  test "the settings pool section is wind-down only when the flag is off" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings"

    assert_response :success
    assert_match(/not available for this collective/i, response.body)
    assert_no_match(/Save Ceiling/, response.body, "the draw ceiling must not be editable while the flag is off")
    assert_no_match(/>Enroll in Pool</, response.body)
    assert_no_match(/Attach an enrolled member/, response.body)
    assert_match(/Withdraw from Pool/, response.body)
    assert_match(/Detach/, response.body)
    assert_match(/Close Funding Pool/, response.body)
  end

  test "the enroll_in_funding_pool action is refused when the flag is off" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/enroll_in_funding_pool", params: {}.to_json, headers: headers

    assert_response :not_found
    assert_not active_enrollment?(pool, @user)
  end

  test "the markdown settings page shows the funding pool state" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 150)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user, name: "Pool Md Bot")
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/Funding Pool/, response.body)
    assert_match(/\$1\.50/, response.body)
    assert_match "Pool Md Bot", response.body
    assert_match(/enrolled/i, response.body)
  end

  # === Persona navigation links ===

  test "the settings trio section links each persona's task runs and automations" do
    collective = create_test_collective
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    FeatureFlagService.config["trio"] ||= {}
    FeatureFlagService.config["trio"]["app_enabled"] = true
    @tenant.enable_feature_flag!("trio")
    collective.enable_feature_flag!("trio")
    PersonaActivator.activate!(collective)
    melody_handle = collective.persona_user("melody").tenant_users.find_by(tenant: @tenant).handle
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings"

    assert_response :success
    assert_includes response.body, "/ai-agents/#{melody_handle}/runs"
    assert_includes response.body, "/ai-agents/#{melody_handle}/automations"

    get "#{collective.path}/settings", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "/ai-agents/#{melody_handle}/runs"
    assert_includes response.body, "/ai-agents/#{melody_handle}/automations"
  end

  # === Member-facing pool page ===

  def record_pool_spend!(pool, stripe_id:, cents:, agent:)
    LLMUsageRecord.create!(
      selection_id: "sel_#{SecureRandom.uuid}",
      status: "completed",
      ai_agent_id: agent.id,
      payer_stripe_customer_id: stripe_id,
      origin_tenant_id: @tenant.id,
      funding_pool_id: pool.id,
      estimated_cost_cents: cents,
      occurred_at: Time.current,
      completed_at: Time.current,
    )
  end

  test "the pool page shows member and agent spend for the last 30 days" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user, stripe_id: "cus_pool_spend")
    enroll!(pool, @user)
    alpha = create_ai_agent(parent: @user, name: "Alpha Bot")
    beta = create_ai_agent(parent: @user, name: "Beta Bot")
    @tenant.add_user!(alpha)
    @tenant.add_user!(beta)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    alpha.update!(funding_pool: pool)
    beta.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    record_pool_spend!(pool, stripe_id: "cus_pool_spend", cents: 100, agent: alpha)
    record_pool_spend!(pool, stripe_id: "cus_pool_spend", cents: 50, agent: beta)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_match(/Usage \(last 30 days\)/, response.body)
    assert_match(/\$1\.50/, response.body) # member total and pool total
    assert_match(/\$1\.00/, response.body) # Alpha Bot's spend
    assert_match(/\$0\.50/, response.body) # Beta Bot's spend
  end

  test "the pool page renders member and agent tables and highlights the current user's rows" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user, stripe_id: "cus_you")
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user, name: "Your Bot")
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_match(/<th[^>]*>\s*Ceiling/, response.body)
    assert_match(/<th[^>]*>\s*Enrolled/, response.body)
    assert_match(/<th[^>]*>\s*Max possible per 30 days/, response.body)
    assert_match(/<th[^>]*>\s*Principal/, response.body)
    # The current user is highlighted both as an enrolled member and as the
    # principal of a funded agent.
    assert response.body.scan("pulse-row-you").size >= 2,
           "expected the current user's member row and their agent's row to be highlighted"
    # Each table carries a totals row summing the last-30-days column.
    assert response.body.scan("pulse-table-total").size >= 2,
           "expected a totals row on both the members and agents tables"
    # The $5.00/day ceiling translates to a 30-day max of $150.00 (× 30 days),
    # with the calculation exposed as a title tooltip.
    assert_includes response.body, "title=\"$5.00/day × 30 days = $150.00\""
  end

  test "the pool page totals do not truncate fractional cents" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user, stripe_id: "cus_frac")
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user, name: "Frac Bot")
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    record_pool_spend!(pool, stripe_id: "cus_frac", cents: 64.66044, agent: agent)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    # The member and agent totals round the same fractional sum; the agent
    # total must not be truncated to $0.64.
    assert_not_includes response.body, "$0.64"
    assert_operator response.body.scan("$0.65").size, :>=, 2
  end

  test "the pool page shows the maximum possible draw as pool ceiling times member count" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective) # pool ceiling $5.00 / day
    fund_user!(@user)
    enroll!(pool, @user, draw_cap_cents: 500)
    # A second member who sets a *lower* personal ceiling — the maximum is the
    # pool ceiling times member count, independent of what members choose.
    frugal = add_funded_member!(collective, name: "Frugal Member")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    pool.enroll!(frugal, draw_cap_cents: 100, draw_cap_period: "day")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_match(/Maximum Possible Draw/, response.body)
    # $5.00 / day / member × 2 members = $10.00 / day
    assert_match(%r{/ day / member}, response.body)
    assert_match(/2 members/, response.body)
    assert_match(%r{\$10\.00 / day}, response.body) # $5.00 pool ceiling × 2 members
    assert_match(/Last 30 days \(actual\)/, response.body)
    # Only the actual-spend column is totaled; the max-possible column is not,
    # to avoid drawing the eye to a hypothetical sum.
    assert_no_match(/\$180\.00/, response.body)
  end

  test "the markdown pool page shows spend figures" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user, stripe_id: "cus_pool_md")
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user, name: "Ledger Bot")
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    record_pool_spend!(pool, stripe_id: "cus_pool_md", cents: 275, agent: agent)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/Spend \(last 30 days\)/, response.body)
    assert_match(/\$2\.75/, response.body)
    assert_match(/Ledger Bot/, response.body)
  end

  def add_funded_member!(collective, name: "Pool Member")
    member = create_user(name: name)
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    member
  end

  test "a non-admin member can enroll and withdraw from the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"
    assert_response :success
    assert_match(/consenting to fund/i, response.body)
    assert_match(/Enroll/, response.body)

    post "#{collective.path}/settings/enroll_in_funding_pool", params: { daily_draw_cap: "3.00" }
    assert_redirected_to "#{collective.path}/pool"
    assert active_enrollment?(pool, member)

    get "#{collective.path}/pool"
    assert_match(/Withdraw/, response.body)

    delete "#{collective.path}/settings/withdraw_from_funding_pool"
    assert_redirected_to "#{collective.path}/pool"
    assert_not active_enrollment?(pool, member)
  end

  test "the pool page shows pool state without admin controls" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 150)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user, name: "Pool Page Bot")
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_match(/\$1\.50/, response.body)
    assert_match "Pool Page Bot", response.body
    assert_match @user.name, response.body
    assert_no_match(/Close Funding Pool/, response.body)
    assert_no_match(/Attach/, response.body)
  end

  test "the pool page redirects when the collective has no pool" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_redirected_to collective.path
  end

  # Withdrawal never detaches agents — their calls are simply refused until
  # the principal re-enrolls. The rosters must SAY that, or a withdrawn
  # member sees their agents still listed as funded and reasonably concludes
  # withdrawal didn't work.
  test "funded agents whose principal is not enrolled are marked as not running" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enrollment = enroll!(pool, @user)
    agent = create_ai_agent(parent: @user, name: "Orphaned Pool Bot")
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    enrollment.withdraw!
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"
    assert_response :success
    assert_match "Orphaned Pool Bot", response.body
    assert_match(/principal not enrolled/i, response.body)

    get "#{collective.path}/pool", headers: { "Accept" => "text/markdown" }
    assert_match(/principal not enrolled/i, response.body)

    get "#{collective.path}/settings"
    assert_match(/principal not enrolled/i, response.body)

    get "#{collective.path}/settings", headers: { "Accept" => "text/markdown" }
    assert_match(/principal not enrolled/i, response.body)
  end

  test "funded agents with enrolled principals carry no not-running marker" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user, name: "Running Pool Bot")
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"
    assert_match "Running Pool Bot", response.body
    assert_no_match(/principal not enrolled/i, response.body)
  end

  test "a closed pool page still offers withdrawal but not enrollment" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = add_funded_member!(collective)
    enroll!(pool, member)
    pool.archive!
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_match(/closed/i, response.body)
    assert_match(/Withdraw/, response.body)
    assert_no_match(/>Enroll in Pool</, response.body)

    delete "#{collective.path}/settings/withdraw_from_funding_pool"
    assert_not active_enrollment?(pool, member)
  end

  test "the markdown pool page offers enroll to members and withdraw only to enrolled ones" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/enroll_in_funding_pool/, response.body)
    assert_no_match(/withdraw_from_funding_pool/, response.body)

    enroll!(pool, member)
    get "#{collective.path}/pool", headers: { "Accept" => "text/markdown" }
    # Enroll stays offered to enrolled members — re-enrolling updates their ceiling.
    assert_match(/enroll_in_funding_pool/, response.body)
    assert_match(/withdraw_from_funding_pool/, response.body)
  end

  test "the pool-page action routes execute for a non-admin member" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/pool/actions/enroll_in_funding_pool", params: { daily_draw_cap: "3.00" }.to_json, headers: headers
    assert_response :success
    assert active_enrollment?(pool, member)
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: member.id)
    assert_equal 300, enrollment.draw_cap_cents

    post "#{collective.path}/pool/actions/withdraw_from_funding_pool", params: {}.to_json, headers: headers
    assert_response :success
    assert_not active_enrollment?(pool, member)
  end

  test "the enroll action requires a ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/pool/actions/enroll_in_funding_pool", params: {}.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_match(/ceiling/i, response.body)
    assert_not active_enrollment?(pool, member)
  end

  test "non-members are bounced from the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    outsider = create_user(name: "Pool Outsider")
    @tenant.add_user!(outsider)
    sign_in_as(outsider, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_redirected_to "#{collective.path}/join"
  end

  # === Funding pool markdown actions ===

  test "the enroll_in_funding_pool action enrolls the caller" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/enroll_in_funding_pool", params: { daily_draw_cap: "5.00" }.to_json, headers: headers

    assert_response :success
    assert active_enrollment?(pool, @user)
  end

  test "the enroll_in_funding_pool action explains an unfunded refusal" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/enroll_in_funding_pool", params: { daily_draw_cap: "5.00" }.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_match(/billing/i, response.body)
    assert_not active_enrollment?(pool, @user)
  end

  test "the enroll_in_funding_pool action accepts a draw_cap_period" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/enroll_in_funding_pool",
         params: { daily_draw_cap: "5.00", draw_cap_period: "month" }.to_json, headers: headers

    assert_response :success
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal "month", enrollment.draw_cap_period
  end

  test "the enroll_in_funding_pool action refuses an invalid draw_cap_period" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/enroll_in_funding_pool",
         params: { daily_draw_cap: "5.00", draw_cap_period: "fortnight" }.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_not active_enrollment?(pool, @user)
  end

  test "the withdraw_from_funding_pool action withdraws the caller" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/withdraw_from_funding_pool", params: {}.to_json, headers: headers

    assert_response :success
    assert_not active_enrollment?(pool, @user)
  end

  test "the attach_funded_agent action attaches an enrolled member's agent" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/attach_funded_agent",
         params: { ai_agent_id: agent.id }.to_json, headers: headers

    assert_response :success
    assert_equal pool.id, agent.reload.funding_pool_id
  end

  test "the detach_funded_agent action detaches a funded agent" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent.update!(funding_pool: pool)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/settings/actions/detach_funded_agent",
         params: { ai_agent_id: agent.id }.to_json, headers: headers

    assert_response :success
    assert_nil agent.reload.funding_pool_id
  end

  test "internal-only collective types cannot be created through the public path" do
    sign_in_as(@user, tenant: @tenant)

    ["chat", "agent_funding"].each do |requested_type|
      handle = "sneaky-#{SecureRandom.hex(4)}"
      post "/collectives", params: { name: "Sneaky", handle: handle, collective_type: requested_type }
      assert_nil Collective.tenant_scoped_only(@tenant.id).find_by(handle: handle),
                 "expected #{requested_type} to be rejected on the public create path"
    end
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
