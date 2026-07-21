require "test_helper"

class CollectiveAgentsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    collective_member = @collective.collective_members.find_by(user: @user)
    collective_member&.add_role!("admin")
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
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

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  def offer_trio!(tenant)
    FeatureFlagService.config["trio"] ||= {}
    FeatureFlagService.config["trio"]["app_enabled"] = true
    tenant.enable_feature_flag!("trio")
  end

  def enable_trio!(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.set_feature_flag!("trio", true)
    PersonaActivator.reconcile!(collective)
  ensure
    Tenant.clear_thread_scope
  end

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

  def fund_user!(user, stripe_id: "cus_#{SecureRandom.hex(6)}")
    existing = StripeCustomer.find_by(billable: user)
    if existing
      existing.update!(active: true, pricing_plan_subscription_id: existing.pricing_plan_subscription_id || "bpps_#{SecureRandom.hex(4)}")
    else
      StripeCustomer.create!(
        billable: user, stripe_id: stripe_id, active: true, pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}",
      )
    end
  end

  def enroll!(pool, user, draw_cap_cents: 500)
    fund_user!(user)
    user.reload
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    pool.enroll!(user, draw_cap_cents: draw_cap_cents)
  ensure
    Tenant.clear_thread_scope
  end

  def create_member_agent!(collective, name:, parent:)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent = User.create!(
      name: name,
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: parent.id,
    )
    @tenant.add_user!(agent)
    CollectiveMember.create!(collective: collective, user: agent)
    agent
  ensure
    Tenant.clear_thread_scope
  end

  def persona_count(collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.reload.persona_users.size
  ensure
    Tenant.clear_thread_scope
  end

  def trio_flag(collective)
    collective.reload.settings.dig("feature_flags", "trio")
  end

  # === The page ===

  test "the agents page renders for a collective admin with the trio toggle" do
    collective = create_test_collective
    offer_trio!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    assert_includes response.body, "Trio"
    assert_includes response.body, "Enable Trio"
  end

  test "a plain member sees the page without the trio toggle" do
    collective = create_test_collective
    offer_trio!(@tenant)
    member = create_user(name: "Plain Member")
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    assert_includes response.body, "Trio"
    assert_not_includes response.body, "Enable Trio"
  end

  test "a private workspace has no agents page" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    workspace = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "My Workspace",
      handle: "agents-test-workspace-#{SecureRandom.hex(4)}",
      collective_type: "private_workspace",
    )
    workspace.add_user!(@user)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{workspace.path}/agents"

    assert_redirected_to workspace.path
  end

  test "the free tier on a billing tenant gets the upgrade pointer instead of the toggle" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    assert_includes response.body, "#{collective.path}/upgrade"
    assert_not_includes response.body, "Enable Trio"
    # The plan-gate copy lists the actual paid features (from paid_feature_labels),
    # not a hardcoded "…and more". On the Agents page the built-in agents are
    # named "Trio" — the page's own Trio section makes the name self-evident.
    assert_includes response.body, "unlocks automations and Trio on this collective"
    assert_not_includes response.body, "the built-in agents (Melody"
    assert_not_includes response.body, "and more"
  end

  test "the paid tier on a billing tenant gets the full page" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_stripe_billing_flag!(@tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    upgrade_collective_to_paid!(collective)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    assert_not_includes response.body, "#{collective.path}/upgrade"
    assert_includes response.body, "Enable Trio"
  end

  test "enabled trio without an open pool warns that it cannot run" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_self_serve_pools!(collective)
    enable_trio!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    # Enabled-without-a-pool is framed as unfinished setup, not "enabled but broken".
    assert_includes response.body, "needs an open funding pool"
    assert_includes response.body, "#{collective.path}/pool"
    assert_not_includes response.body, "Trio is on"
  end

  test "the cannot-run warning clears once a pool is open" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_self_serve_pools!(collective)
    enable_trio!(collective)
    create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    assert_not_includes response.body, "needs an open funding pool"
    assert_includes response.body, "Trio is on"
  end

  test "the pool summary shows state and enrollment count, without the ceiling detail" do
    collective = create_test_collective
    enable_self_serve_pools!(collective)
    pool = create_pool!(collective)
    enroll!(pool, @user)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    assert_includes response.body, "1 member enrolled"
    assert_includes response.body, "#{collective.path}/pool"
    # Ceiling detail lives on the pool page, not the agents summary.
    assert_not_includes response.body, "per member per"
  end

  test "agent members list personas and member-added agents alike, with their principals" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_trio!(collective)
    create_member_agent!(collective, name: "Robo Helper", parent: @user)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"

    assert_response :success
    members_section = css_select("#agent-members").first
    assert members_section, "expected an #agent-members section"
    assert_includes members_section.to_s, "Robo Helper"
    assert_includes members_section.to_s, @user.name
    assert_includes members_section.to_s, "Melody"
  end

  test "the markdown view renders" do
    collective = create_test_collective
    offer_trio!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "# Agents"
    assert_includes response.body, "Trio"
  end

  # === The trio toggle endpoint ===

  test "the agents page points at the members page for membership ops" do
    collective = create_test_collective
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/agents"
    assert_response :success
    assert_select "a[href=?]", "#{collective.path}/members"
    assert_match(/manage agent membership on the/i, response.body)

    get "#{collective.path}/agents", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "#{collective.path}/members"
  end

  test "an admin enables trio and the personas activate" do
    collective = create_test_collective
    offer_trio!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/agents/set_trio_enabled", params: { enabled: "true" }

    assert_redirected_to "#{collective.path}/agents"
    assert_equal true, trio_flag(collective)
    assert_equal 3, persona_count(collective)
  end

  test "enabling trio without an open pool flashes a pool-page pointer" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_self_serve_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/agents/set_trio_enabled", params: { enabled: "true" }

    assert_redirected_to "#{collective.path}/agents"
    assert_includes flash[:notice].to_s, "#{collective.path}/pool"

    create_pool!(collective)
    post "#{collective.path}/agents/set_trio_enabled", params: { enabled: "true" }
    assert_not_includes flash[:notice].to_s, "#{collective.path}/pool"
  end

  test "an admin disables trio and the personas deactivate" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_trio!(collective)
    assert_equal 3, persona_count(collective), "precondition: ensemble active"
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/agents/set_trio_enabled", params: { enabled: "false" }

    assert_redirected_to "#{collective.path}/agents"
    assert_equal false, trio_flag(collective)
    assert_equal 0, persona_count(collective)
  end

  test "a plain member cannot toggle trio" do
    collective = create_test_collective
    offer_trio!(@tenant)
    member = create_user(name: "Plain Member")
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/agents/set_trio_enabled", params: { enabled: "true" }

    assert_not_equal true, trio_flag(collective)
    assert_equal 0, persona_count(collective)
  end

  test "enabling trio requires the paid plan on a billing tenant" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/agents/set_trio_enabled", params: { enabled: "true" }

    assert_not_equal true, trio_flag(collective)
    assert_equal 0, persona_count(collective)
  end

  test "disabling trio stays allowed after the paid tier lapses" do
    collective = create_test_collective
    offer_trio!(@tenant)
    enable_stripe_billing_flag!(@tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    upgrade_collective_to_paid!(collective)
    Tenant.clear_thread_scope
    enable_trio!(collective)
    assert_equal 3, persona_count(collective), "precondition: ensemble active"
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.update!(tier: Collective::TIER_LAPSED)
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/agents/set_trio_enabled", params: { enabled: "false" }

    assert_redirected_to "#{collective.path}/agents"
    assert_equal false, trio_flag(collective)
    assert_equal 0, persona_count(collective)
  end

  # === The actions index and described action ===

  test "the agents actions index offers the trio toggle to admins only" do
    collective = create_test_collective
    offer_trio!(@tenant)
    member = create_user(name: "Plain Member")
    add_member!(collective, member)

    sign_in_as(@user, tenant: @tenant)
    get "#{collective.path}/agents/actions", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "set_trio_enabled"

    sign_in_as(member, tenant: @tenant)
    get "#{collective.path}/agents/actions", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "set_trio_enabled"
  end

  test "set_trio_enabled executes as a described action" do
    collective = create_test_collective
    offer_trio!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/agents/actions/set_trio_enabled",
         params: { enabled: "true" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :success
    assert_equal true, trio_flag(collective)
    assert_equal 3, persona_count(collective)
  end

  test "the set_trio_enabled action is forbidden for non-admin members" do
    collective = create_test_collective
    offer_trio!(@tenant)
    member = create_user(name: "Plain Member")
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/agents/actions/set_trio_enabled",
         params: { enabled: "true" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :forbidden
    assert_not_equal true, trio_flag(collective)
  end
end
