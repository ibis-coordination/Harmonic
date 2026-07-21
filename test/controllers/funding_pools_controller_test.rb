require "test_helper"

class FundingPoolsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    collective_member = @collective.collective_members.find_by(user: @user)
    collective_member.add_role!("admin") if collective_member
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    # Stripe SDK validates that api_key is set before sending requests, even
    # when the HTTP layer is stubbed by WebMock.
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

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

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

  def agent_api_token(agent)
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

  # === Pool-prefixed operation endpoints ===

  test "creating a pool posts to the pool prefix and lands on the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

    assert_redirected_to "#{collective.path}/pool"
    pool = FundingPool.tenant_scoped_only(@tenant.id).find_by(collective_id: collective.id)
    assert pool.present?
    assert_equal 500, pool.member_draw_cap_cents
  end

  test "closing the pool lands back on the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/close_funding_pool"

    assert_redirected_to "#{collective.path}/pool"
    assert pool.reload.archived?
  end

  test "the settings-prefixed pool endpoints are gone" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    [
      -> { post "#{collective.path}/settings/create_funding_pool", params: { member_daily_draw_cap: "5.00" } },
      -> { post "#{collective.path}/settings/enroll_in_funding_pool", params: { ceiling_choice: "pool" } },
      -> { post "#{collective.path}/settings/actions/enroll_in_funding_pool", params: { daily_draw_cap: "2.00" } },
      -> { post "#{collective.path}/settings/actions/attach_funded_agent", params: { ai_agent_id: 1 } },
    ].each do |request|
      raised = false
      begin
        request.call
      rescue ActionController::RoutingError
        raised = true
      end
      assert raised || response.status == 404, "expected the settings-prefixed pool route to be gone"
    end
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  # === The ceiling endpoint ===

  test "an admin can change the pool ceiling from the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/update_ceiling",
         params: { member_daily_draw_cap: "9.00", member_draw_cap_period: "week" }

    assert_redirected_to "#{collective.path}/pool"
    pool.reload
    assert_equal 900, pool.member_draw_cap_cents
    assert_equal "week", pool.member_draw_cap_period
  end

  test "non-admin members cannot change the pool ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/pool/update_ceiling", params: { member_daily_draw_cap: "9.00" }

    assert flash[:alert].present?
    assert_equal 500, pool.reload.member_draw_cap_cents
  end

  test "the ceiling cannot be blanked" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/update_ceiling", params: { member_daily_draw_cap: "" }

    assert flash[:alert].present?
    assert_equal 500, pool.reload.member_draw_cap_cents
  end

  test "ceiling changes are paused while pools are unavailable" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    collective.disable_feature_flag!("funding_pools")
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/update_ceiling", params: { member_daily_draw_cap: "9.00" }

    assert flash[:alert].present?
    assert_equal 500, pool.reload.member_draw_cap_cents
  end

  # === The set_pool_ceiling action ===

  test "the set_pool_ceiling action sets the ceiling and window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_daily_draw_cap: "7.50", member_draw_cap_period: "month" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :success
    pool.reload
    assert_equal 750, pool.member_draw_cap_cents
    assert_equal "month", pool.member_draw_cap_period
  end

  test "the set_pool_ceiling action refuses a blank ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_daily_draw_cap: "" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :unprocessable_entity
    assert_equal 500, pool.reload.member_draw_cap_cents
  end

  test "the set_pool_ceiling action is forbidden for non-admin members" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_daily_draw_cap: "7.50" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :forbidden
    assert_equal 500, pool.reload.member_draw_cap_cents
  end

  # === update_collective_settings no longer reaches into the pool ===

  test "the update_collective_settings action ignores ceiling params" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings/actions/update_collective_settings",
         params: { member_daily_draw_cap: "9.00", name: "Renamed by action" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :success
    assert_equal 500, pool.reload.member_draw_cap_cents, "the settings action must not touch the pool ceiling"
    assert_equal "Renamed by action", collective.reload.name
  end

  test "the plain settings form ignores ceiling params" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/settings",
         params: { member_daily_draw_cap: "9.00", name: "Renamed" },
         headers: { "Referer" => "#{collective.url}/settings" }

    assert_equal 500, pool.reload.member_draw_cap_cents, "the settings form must not touch the pool ceiling"
    assert_equal "Renamed", collective.reload.name
  end

  test "an un-enrolled member without credits gets a top-up link that returns to the pool" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    member = create_user(name: "Broke Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "a[href=?]", "/billing?return_to=#{CGI.escape("#{collective.path}/pool")}"
  end

  test "a member with funded billing sees no top-up prompt" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    member = create_user(name: "Funded Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "a[href^=?]", "/billing?return_to=", count: 0
    # The pool page distinguishes prepaid usage credits from the $3/month plan.
    assert_match(/separate from the collective's \$3\/month plan/i, response.body)
  end

  # === The pool page without a pool ===

  test "an admin without a pool sees the open-pool form on the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "form[action=?]", "#{collective.path}/pool/create_funding_pool"
  end

  test "a member without a pool sees a no-pool notice, not the open form" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "form[action=?]", "#{collective.path}/pool/create_funding_pool", count: 0
    assert_includes response.body, "no funding pool"
  end

  test "the pool page still redirects when pools are unavailable and none exists" do
    collective = create_test_collective
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_redirected_to collective.path
  end

  # === Admin controls on the pool page ===

  test "an admin sees ceiling and close controls on the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "form[action=?]", "#{collective.path}/pool/update_ceiling"
    assert_select "form[action=?]", "#{collective.path}/pool/close_funding_pool"
  end

  test "a member sees no admin controls on the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "form[action=?]", "#{collective.path}/pool/update_ceiling", count: 0
    assert_select "form[action=?]", "#{collective.path}/pool/close_funding_pool", count: 0
  end

  test "a lapsed pool offers admins wind-down controls on the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    collective.disable_feature_flag!("funding_pools")
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    # Wind-down: close stays available, but not ceiling changes or reopening.
    assert_select "form[action=?]", "#{collective.path}/pool/close_funding_pool"
    assert_select "form[action=?]", "#{collective.path}/pool/update_ceiling", count: 0
  end

  # === Settings page hands the pool off ===

  test "the settings page hosts no pool controls" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/settings"

    assert_response :success
    # The pool has its own page (linked from the sidebar menu); settings hosts
    # neither its controls nor a pointer to it.
    assert_select "form[action=?]", "#{collective.path}/pool/create_funding_pool", count: 0
    assert_select "form[action=?]", "#{collective.path}/pool/update_ceiling", count: 0
    assert_select "form[action=?]", "#{collective.path}/pool/close_funding_pool", count: 0
  end

  # === Actions indexes follow the responsibility split ===

  test "the pool actions index lists admin pool actions and the settings index does not" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown" }

    get "#{collective.path}/pool/actions", headers: headers
    assert_response :success
    assert_includes response.body, "attach_funded_agent"
    assert_includes response.body, "detach_funded_agent"
    assert_includes response.body, "set_pool_ceiling"

    get "#{collective.path}/settings/actions", headers: headers
    assert_response :success
    assert_not_includes response.body, "enroll_in_funding_pool"
    assert_not_includes response.body, "attach_funded_agent"
  end

  test "the pool actions index hides admin actions from plain members" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool/actions", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "enroll_in_funding_pool"
    assert_not_includes response.body, "attach_funded_agent"
    assert_not_includes response.body, "set_pool_ceiling"
  end

  # === Test data helpers ===

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

  def add_funded_member!(collective, name: "Pool Member")
    member = create_user(name: name)
    @tenant.add_user!(member)
    add_member!(collective, member)
    fund_user!(member)
    member
  end

  # === Opening a pool ===

  test "an admin can open a pool with a weekly ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool",
         params: { member_daily_draw_cap: "5.00", member_draw_cap_period: "week" }

    assert_redirected_to "#{collective.path}/pool"
    pool = FundingPool.tenant_scoped_only(@tenant.id).find_by(collective_id: collective.id)
    assert pool.present?
    assert_equal 500, pool.member_draw_cap_cents
    assert_equal "week", pool.member_draw_cap_period
  end

  test "opening a pool with an invalid ceiling window is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool",
         params: { member_daily_draw_cap: "5.00", member_draw_cap_period: "fortnight" }

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "creating a pool without a draw ceiling is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool"

    assert flash[:alert].present?, "expected a friendly refusal — every pool needs an explicit ceiling"
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)

    post "#{collective.path}/pool/create_funding_pool", params: { member_daily_draw_cap: "not money" }

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

    post "#{collective.path}/pool/create_funding_pool"

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "creating a pool requires the stripe_billing feature" do
    collective = create_test_collective
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool"

    assert flash[:alert].present?
    assert_not FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "creating a pool requires the funding_pools flag" do
    enable_stripe_billing_flag!(@tenant)
    collective = create_test_collective
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool"

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

    post "#{collective.path}/pool/create_funding_pool"

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

    post "#{chat.path}/pool/create_funding_pool"

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

    post "#{collective.path}/pool/create_funding_pool"

    assert_redirected_to "#{collective.path}/pool"
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

    post "#{collective.path}/pool/create_funding_pool", params: { member_daily_draw_cap: "2.50" }

    pool.reload
    assert_not pool.archived?
    assert_equal 250, pool.member_draw_cap_cents
  end

  # === Self-serve pools ===

  test "a paid-tier collective admin can open a pool self-serve without the operator flag" do
    collective = create_test_collective
    enable_self_serve_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

    assert_redirected_to "#{collective.path}/pool"
    assert FundingPool.tenant_scoped_only(@tenant.id).exists?(collective_id: collective.id)
  end

  test "a free-tier collective cannot open a pool without the operator flag" do
    collective = create_test_collective
    enable_stripe_billing_flag!(@tenant)
    FeatureFlagService.config["funding_pools"] ||= {}
    FeatureFlagService.config["funding_pools"]["app_enabled"] = true
    @tenant.enable_feature_flag!("funding_pools")
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

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

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { ceiling_choice: "pool" }

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

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }

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

    post "#{collective.path}/pool/create_funding_pool", params: { member_daily_draw_cap: "5.00" }

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
    post "#{collective.path}/pool/create_funding_pool", params: { member_daily_draw_cap: "5.00" }
    pool = FundingPool.tenant_scoped_only(@tenant.id).find_by(collective_id: collective.id)
    assert_equal pool.id, trio.reload.funding_pool_id

    delete "#{collective.path}/pool/remove_funded_agent", params: { ai_agent_id: trio.id }

    assert flash[:alert].present?, "expected detaching the persona to be refused"
    assert_equal pool.id, trio.reload.funding_pool_id, "the persona must stay on the pool payroll"
  end

  # === Closing the pool ===

  test "non-admins cannot close the pool" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = create_user(name: "Plain Member")
    @tenant.add_user!(member)
    add_member!(collective, member)
    sign_in_as(member, tenant: @tenant)

    post "#{collective.path}/pool/close_funding_pool"

    assert flash[:alert].present?
    assert_not pool.reload.archived?
  end

  # === Enrollment ===

  test "a funded member can enroll themselves with their own ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { daily_draw_cap: "3.00" }

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

    post "#{collective.path}/pool/enroll_in_funding_pool",
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

    post "#{collective.path}/pool/enroll_in_funding_pool"

    assert_redirected_to "#{collective.path}/pool"
    assert_match(/ceiling/i, flash[:alert], "consent must state an explicit ceiling")
    assert_not active_enrollment?(pool, @user)

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { daily_draw_cap: "several" }

    assert flash[:alert].present?
    assert_not active_enrollment?(pool, @user)
  end

  test "enrolling with the pool-ceiling choice adopts the pool's current ceiling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { ceiling_choice: "pool" }

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

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { ceiling_choice: "custom" }

    assert_redirected_to "#{collective.path}/pool"
    assert_match(/ceiling/i, flash[:alert])
    assert_not active_enrollment?(pool, @user)
  end

  test "an enrolled member can update their ceiling by re-enrolling" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { daily_draw_cap: "1.25" }

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

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { daily_draw_cap: "3.00" }

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

    delete "#{collective.path}/pool/withdraw_from_funding_pool"

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

    delete "#{collective.path}/pool/withdraw_from_funding_pool"

    assert_match(/stay attached/, flash[:notice])
    assert_match(/calls are refused/, flash[:notice])
  end

  test "enrolling above the pool ceiling notes that the pool ceiling applies" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { daily_draw_cap: "50.00" }

    assert active_enrollment?(pool, @user)
    assert_match(/pool's \$5\.00 ceiling applies/, flash[:notice])
  end

  test "a funded member can enroll with a weekly ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/enroll_in_funding_pool",
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

    post "#{collective.path}/pool/enroll_in_funding_pool",
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

    post "#{collective.path}/pool/enroll_in_funding_pool",
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

    post "#{collective.path}/pool/enroll_in_funding_pool",
         params: { ceiling_choice: "custom", daily_draw_cap: "3.00", draw_cap_period: "month" }

    assert_redirected_to "#{collective.path}/pool"
    enrollment = FundingPoolEnrollment.tenant_scoped_only(@tenant.id).find_by!(funding_pool_id: pool.id, user_id: @user.id)
    assert_equal 300, enrollment.draw_cap_cents
    assert_equal "month", enrollment.draw_cap_period
  end

  # === Funded agents (attach and detach) ===

  test "an admin can attach an enrolled member's agent" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    enroll!(pool, @user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }

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

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/pool"
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

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }, as: :json

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

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/pool"
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

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/pool"
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

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }, as: :json

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

    get "#{collective.path}/pool"

    assert_response :success
    assert_match "Local Fund Bot", response.body
    assert_no_match(/Foreign Fund Bot/, response.body)
  end

  test "detaching an agent not funded by this pool redirects with an alert" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    fund_user!(@user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)

    delete "#{collective.path}/pool/remove_funded_agent", params: { ai_agent_id: agent.id }

    assert_redirected_to "#{collective.path}/pool"
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

    delete "#{collective.path}/pool/remove_funded_agent", params: { ai_agent_id: agent.id }

    assert_response :redirect
    assert_nil agent.reload.funding_pool_id
  end

  # === Flag gating ===

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

    post "#{collective.path}/pool/enroll_in_funding_pool"

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

    post "#{collective.path}/pool/add_funded_agent", params: { ai_agent_id: agent.id }

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

    delete "#{collective.path}/pool/withdraw_from_funding_pool"
    assert_not active_enrollment?(pool, @user), "withdrawal is a consent exit and must never be flag-gated"

    delete "#{collective.path}/pool/remove_funded_agent", params: { ai_agent_id: agent.id }
    assert_nil agent.reload.funding_pool_id, "detach stops spending and must never be flag-gated"
  end

  # === The ceiling endpoint, ported settings-form semantics ===

  test "an invalid ceiling window on the ceiling endpoint is refused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/update_ceiling",
         params: { member_daily_draw_cap: "0.50", member_draw_cap_period: "fortnight" }

    assert flash[:alert].present?
    pool.reload
    assert_equal 500, pool.member_draw_cap_cents, "an invalid window must not change the ceiling"
    assert_equal "day", pool.member_draw_cap_period
  end

  test "an over-large draw ceiling is rejected with a friendly error" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 50)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/update_ceiling", params: { member_daily_draw_cap: "30000000" }

    assert_response :redirect
    assert flash[:alert].present?
    assert_equal 50, pool.reload.member_draw_cap_cents
  end

  test "the pool page ceiling form offers a window selector" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    get "#{collective.path}/pool"

    assert_response :success
    assert_select "form[action=?]", "#{collective.path}/pool/update_ceiling" do
      assert_select "select[name=?]", "member_draw_cap_period" do
        assert_select "option[value=?]", "day"
        assert_select "option[value=?]", "week"
        assert_select "option[value=?]", "month"
      end
    end
  end

  # === The set_pool_ceiling action, ported update_collective_settings semantics ===

  test "the set_pool_ceiling action refuses an invalid ceiling window" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_daily_draw_cap: "0.75", member_draw_cap_period: "fortnight" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :unprocessable_entity
    pool.reload
    assert_equal 500, pool.member_draw_cap_cents, "an invalid window must not change the ceiling"
    assert_equal "day", pool.member_draw_cap_period
  end

  test "the set_pool_ceiling action refuses a period-only change" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_draw_cap_period: "week" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :unprocessable_entity
    assert_match(/dollar amount/, response.body)
    assert_equal "day", pool.reload.member_draw_cap_period, "a period-only change must not silently take effect"
  end

  test "the set_pool_ceiling action rejects a bad draw ceiling with a friendly message" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 50)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_daily_draw_cap: "lots" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :unprocessable_entity
    assert_no_match(/BigDecimal/, response.body, "internal parse errors must not leak to the action API")
    assert_equal 50, pool.reload.member_draw_cap_cents
  end

  test "the set_pool_ceiling action is refused while pools are paused" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    pool.update!(member_draw_cap_cents: 50)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    collective.disable_feature_flag!("funding_pools")
    Tenant.clear_thread_scope
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_daily_draw_cap: "0.75" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :forbidden
    assert_match(/paused/i, response.body)
    assert_equal 50, pool.reload.member_draw_cap_cents
  end

  test "the set_pool_ceiling action without a pool fails with a friendly message" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    sign_in_as(@user, tenant: @tenant)

    post "#{collective.path}/pool/actions/set_pool_ceiling",
         params: { member_daily_draw_cap: "0.75" }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :not_found
    assert_match(/no funding pool/i, response.body)
  end

  # === Wind-down mode ===

  test "the pool page is wind-down only when the flag is off" do
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

    get "#{collective.path}/pool"

    assert_response :success
    assert_match(/not available for this collective/i, response.body)
    assert_no_match(/Save Ceiling/, response.body, "the draw ceiling must not be editable while the flag is off")
    assert_no_match(/>Enroll in Pool</, response.body)
    assert_no_match(/Attach an Enrolled Member/, response.body)
    assert_match(/Withdraw from Pool/, response.body)
    assert_match(/Detach/, response.body)
    assert_match(/Close Funding Pool/, response.body)

    get "#{collective.path}/pool", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/not available for this collective/i, response.body)
  end

  # === The member-facing pool page ===

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

  test "a non-admin member can enroll and withdraw from the pool page" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    member = add_funded_member!(collective)
    sign_in_as(member, tenant: @tenant)

    get "#{collective.path}/pool"
    assert_response :success
    assert_match(/consenting to fund/i, response.body)
    assert_select "form[action=?]", "#{collective.path}/pool/enroll_in_funding_pool"

    post "#{collective.path}/pool/enroll_in_funding_pool", params: { daily_draw_cap: "3.00" }
    assert_redirected_to "#{collective.path}/pool"
    assert active_enrollment?(pool, member)

    get "#{collective.path}/pool"
    assert_match(/Withdraw/, response.body)

    delete "#{collective.path}/pool/withdraw_from_funding_pool"
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

    delete "#{collective.path}/pool/withdraw_from_funding_pool"
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

  # === The pool markdown actions ===

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

  test "the enroll_in_funding_pool action enrolls the caller" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    fund_user!(@user)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/pool/actions/enroll_in_funding_pool", params: { daily_draw_cap: "5.00" }.to_json, headers: headers

    assert_response :success
    assert active_enrollment?(pool, @user)
  end

  test "the enroll_in_funding_pool action explains an unfunded refusal" do
    collective = create_test_collective
    enable_funding_pools!(collective)
    pool = create_pool!(collective)
    sign_in_as(@user, tenant: @tenant)
    headers = { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    post "#{collective.path}/pool/actions/enroll_in_funding_pool", params: { daily_draw_cap: "5.00" }.to_json, headers: headers

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

    post "#{collective.path}/pool/actions/enroll_in_funding_pool",
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

    post "#{collective.path}/pool/actions/enroll_in_funding_pool",
         params: { daily_draw_cap: "5.00", draw_cap_period: "fortnight" }.to_json, headers: headers

    assert_response :unprocessable_entity
    assert_not active_enrollment?(pool, @user)
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

    post "#{collective.path}/pool/actions/enroll_in_funding_pool", params: {}.to_json, headers: headers

    assert_response :not_found
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

    post "#{collective.path}/pool/actions/withdraw_from_funding_pool", params: {}.to_json, headers: headers

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

    post "#{collective.path}/pool/actions/attach_funded_agent",
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

    post "#{collective.path}/pool/actions/detach_funded_agent",
         params: { ai_agent_id: agent.id }.to_json, headers: headers

    assert_response :success
    assert_nil agent.reload.funding_pool_id
  end
end
