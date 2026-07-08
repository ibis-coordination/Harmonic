# typed: false

require "test_helper"

class UserDataExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    # Use the tenant's own main_collective so DataExport's collective-scoped
    # default_scope aligns with what the controller queries.
    @collective = @tenant.main_collective
    @user = @global_user
    @collective.add_user!(@user) unless @collective.collective_members.exists?(user_id: @user.id)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)

    # Feature flag gating, same pattern as collective_export.
    @tenant.update!(settings: @tenant.settings.deep_merge("feature_flags" => { "user_data_export" => true }))

    @other_user = create_user(name: "Other")
    @tenant.add_user!(@other_user)

    @user_handle = @user.tenant_users.find_by!(tenant_id: @tenant.id).handle
    @other_handle = @other_user.tenant_users.find_by!(tenant_id: @tenant.id).handle

    # Bypass reverification on the test path by stubbing it. The reverification
    # gate is its own concern, tested below explicitly.
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === Feature flag gating ===

  test "exports index 404s when user_data_export feature flag is disabled" do
    @tenant.update!(settings: @tenant.settings.deep_merge("feature_flags" => { "user_data_export" => false }))
    sign_in_as(@user, tenant: @tenant)

    get "/settings/data-export"
    assert_response :not_found
  end

  # === Rate limit ===

  test "Rack::Attack throttle is registered for POST to the user export endpoint" do
    # The actual middleware-based behavior isn't exercised in the test env,
    # but we pin that the throttle rule exists and matches the correct path
    # — so removing or breaking the regex in rack_attack.rb causes a test
    # failure rather than a silent loss of protection.
    rule = Rack::Attack.throttles["user_data_exports/ip"]
    refute_nil rule, "expected a 'user_data_exports/ip' throttle in rack_attack.rb"

    # Synthesize a request and confirm the rule matches it.
    post_env = Rack::MockRequest.env_for("/u/somehandle/settings/data-export", method: "POST", "REMOTE_ADDR" => "1.2.3.4")
    post_req = Rack::Attack::Request.new(post_env)
    assert_equal "1.2.3.4", rule.block.call(post_req), "throttle should match POST and return the client IP"

    get_env = Rack::MockRequest.env_for("/u/somehandle/settings/data-export", method: "GET", "REMOTE_ADDR" => "1.2.3.4")
    get_req = Rack::Attack::Request.new(get_env)
    assert_nil rule.block.call(get_req), "throttle should not match GETs (read-only)"

    other_env = Rack::MockRequest.env_for("/u/somehandle/settings/profile", method: "POST", "REMOTE_ADDR" => "1.2.3.4")
    other_req = Rack::Attack::Request.new(other_env)
    assert_nil rule.block.call(other_req), "throttle should not match unrelated paths"
  end

  # === API token rejection ===

  test "rejects API-token-authenticated requests with 403" do
    # Personal data export is browser-only. The reverification gate
    # intentionally bypasses for API tokens, but for an action this
    # sensitive we additionally refuse API-token auth at the boundary so
    # a stolen token (even one issued by the legitimate user) can't
    # trigger or download an export.
    api_token = ApiToken.create!(
      tenant: @tenant, user: @user, name: "test", scopes: ApiToken.valid_scopes,
    )
    headers = { "Authorization" => "Bearer #{api_token.plaintext_token}", "Accept" => "text/markdown" }

    [
      [:get, "/settings/data-export"],
      [:post, "/settings/data-export"],
      [:get, "/settings/data-export/some-id"],
    ].each do |method, path|
      send(method, path, headers: headers)
      assert_response :forbidden, "#{method.upcase} #{path} must reject API-token auth (got #{response.status})"
    end
  end

  # === Authorization ===

  test "unauthenticated user is redirected to login" do
    get "/settings/data-export"
    assert_redirected_to "/login"
  end

  # The data-export routes are handle-free (/settings/data-export), so they
  # resolve to the signed-in user and carry no target. The old cross-user vector
  # (visiting /u/<victim>/settings/data-export) no longer exists by
  # construction; these pin that another user can neither view nor create an
  # export against @user.
  test "the handle-free data-export page is scoped to the signed-in user" do
    sign_in_as(@other_user, tenant: @tenant)
    get "/settings/data-export"
    # Resolves to @other_user, never @user — @user's handle/data cannot surface
    # here (it may redirect to reverification first; either way it is not
    # @user's page).
    assert_no_match(/#{@user_handle}/, response.body)
  end

  test "the handle-free export route never creates an export for another user" do
    sign_in_as(@other_user, tenant: @tenant)
    assert_no_difference -> { DataExport.where(user: @user).count } do
      post "/settings/data-export"
    end
  end

  # AI agents cannot trigger their own export. They authenticate via API tokens,
  # not browser sessions, so they can't reach a settings page via cookie auth at
  # all. The controller's require_human_user predicate is a defense-in-depth
  # second gate that runs if browser auth somehow accepted them. The service
  # itself rejects non-human subjects (covered in UserDataExportServiceTest).

  # === Reverification gating ===

  test "redirects to /reverify when the user has 2FA enabled and not yet reverified" do
    identity = @user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!
    sign_in_as(@user, tenant: @tenant)

    get "/settings/data-export"
    assert_redirected_to "/reverify"
  end

  # === Index ===

  test "index lists the user's own data exports" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export")
    older = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user", created_at: 2.days.ago,
    )
    newer = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "user",
    )

    get "/settings/data-export"
    assert_response :success
    assert_match(/Previous Exports/i, response.body)
    assert_match(/Pending/i, response.body)
    assert_match(/Completed/i, response.body)
  end

  test "index does not list other users' exports or collective exports" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export")
    DataExport.create!(
      tenant: @tenant, collective: @collective, user: @other_user,
      status: "completed", export_type: "user",
    )
    DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "collective",
    )

    get "/settings/data-export"
    assert_response :success
    refute_match(
      /Previous Exports/i, response.body,
      "should not render the Previous Exports section: only other-user and collective exports exist (and the user has none of their own)",
    )
  end

  # === Create ===

  test "create enqueues a user export job and creates a DataExport" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export", method: :post)
    assert_difference "DataExport.user_exports.count", 1 do
      assert_enqueued_with(job: UserDataExportJob) do
        post "/settings/data-export"
      end
    end
    export = DataExport.user_exports.order(:created_at).last
    assert_equal @user.id, export.user_id
    assert_equal @tenant.main_collective_id, export.collective_id
    assert_equal "pending", export.status
    assert_redirected_to "/settings/data-export"
  end

  test "create logs a security audit entry" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export", method: :post)
    recorded = []
    SecurityAuditLog.stub(:log_user_action, ->(**kw) { recorded << kw }) do
      post "/settings/data-export"
    end
    assert recorded.any? { |r| r[:action] == "user_data_export_created" && r[:user] == @user },
           "expected user_data_export_created audit log entry, got: #{recorded.inspect}"
  end

  test "create refuses when the user already has an active export" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export", method: :post)
    DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "user",
    )

    assert_no_difference "DataExport.count" do
      post "/settings/data-export"
    end
    assert_redirected_to "/settings/data-export"
    assert_match(/already in progress/i, flash[:alert])
  end

  # === Download ===

  test "download serves the user's own completed export" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export")
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user",
      expires_at: 1.day.from_now,
    )
    export.file.attach(io: StringIO.new("zip content"), filename: "x.zip", content_type: "application/zip")

    get "/settings/data-export/#{export.id}"
    # Redirects to ActiveStorage blob URL with attachment disposition.
    assert_response :redirect
    assert_match(/blob/i, response.location)
  end

  test "download logs a security audit entry" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export")
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user",
      expires_at: 1.day.from_now,
    )
    export.file.attach(io: StringIO.new("zip"), filename: "x.zip", content_type: "application/zip")

    recorded = []
    SecurityAuditLog.stub(:log_user_action, ->(**kw) { recorded << kw }) do
      get "/settings/data-export/#{export.id}"
    end
    assert recorded.any? { |r| r[:action] == "user_data_export_downloaded" && r[:user] == @user }
  end

  test "download refuses someone else's export by id" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export")
    not_mine = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @other_user,
      status: "completed", export_type: "user",
      expires_at: 1.day.from_now,
    )
    not_mine.file.attach(io: StringIO.new("zip"), filename: "x.zip", content_type: "application/zip")

    get "/settings/data-export/#{not_mine.id}"
    assert_response :not_found
  end

  test "download refuses expired exports" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/settings/data-export")
    expired = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user",
      expires_at: 1.day.ago,
    )
    expired.file.attach(io: StringIO.new("zip"), filename: "x.zip", content_type: "application/zip")

    get "/settings/data-export/#{expired.id}"
    assert_redirected_to "/settings/data-export"
    assert_match(/expired/i, flash[:alert])
  end
end
