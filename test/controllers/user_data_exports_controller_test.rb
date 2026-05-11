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

    get "/u/#{@user_handle}/settings/data-export"
    assert_response :not_found
  end

  # === Authorization ===

  test "unauthenticated user is redirected to login" do
    get "/u/#{@user_handle}/settings/data-export"
    assert_redirected_to "/login"
  end

  test "another user cannot access someone else's data export page" do
    sign_in_as(@other_user, tenant: @tenant)
    get "/u/#{@user_handle}/settings/data-export"
    assert_response :forbidden
  end

  test "another user cannot create an export on someone else's behalf" do
    sign_in_as(@other_user, tenant: @tenant)
    assert_no_difference "DataExport.count" do
      post "/u/#{@user_handle}/settings/data-export"
    end
    assert_response :forbidden
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

    get "/u/#{@user_handle}/settings/data-export"
    assert_redirected_to "/reverify"
  end

  # === Index ===

  test "index lists the user's own data exports" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export")
    older = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user", created_at: 2.days.ago,
    )
    newer = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "user",
    )

    get "/u/#{@user_handle}/settings/data-export"
    assert_response :success
    assert_match(/Previous Exports/i, response.body)
    assert_match(/Pending/i, response.body)
    assert_match(/Completed/i, response.body)
  end

  test "index does not list other users' exports or collective exports" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export")
    DataExport.create!(
      tenant: @tenant, collective: @collective, user: @other_user,
      status: "completed", export_type: "user",
    )
    DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "collective",
    )

    get "/u/#{@user_handle}/settings/data-export"
    assert_response :success
    refute_match(
      /Previous Exports/i, response.body,
      "should not render the Previous Exports section: only other-user and collective exports exist (and the user has none of their own)",
    )
  end

  # === Create ===

  test "create enqueues a user export job and creates a DataExport" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export", method: :post)
    assert_difference "DataExport.user_exports.count", 1 do
      assert_enqueued_with(job: UserDataExportJob) do
        post "/u/#{@user_handle}/settings/data-export"
      end
    end
    export = DataExport.user_exports.order(:created_at).last
    assert_equal @user.id, export.user_id
    assert_equal @tenant.main_collective_id, export.collective_id
    assert_equal "pending", export.status
    assert_redirected_to "/u/#{@user_handle}/settings/data-export"
  end

  test "create logs a security audit entry" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export", method: :post)
    recorded = []
    SecurityAuditLog.stub(:log_user_action, ->(**kw) { recorded << kw }) do
      post "/u/#{@user_handle}/settings/data-export"
    end
    assert recorded.any? { |r| r[:action] == "user_data_export_created" && r[:user] == @user },
           "expected user_data_export_created audit log entry, got: #{recorded.inspect}"
  end

  test "create refuses when the user already has an active export" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export", method: :post)
    DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "user",
    )

    assert_no_difference "DataExport.count" do
      post "/u/#{@user_handle}/settings/data-export"
    end
    assert_redirected_to "/u/#{@user_handle}/settings/data-export"
    assert_match(/already in progress/i, flash[:alert])
  end

  # === Download ===

  test "download serves the user's own completed export" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export")
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user",
      expires_at: 1.day.from_now,
    )
    export.file.attach(io: StringIO.new("zip content"), filename: "x.zip", content_type: "application/zip")

    get "/u/#{@user_handle}/settings/data-export/#{export.id}"
    # Redirects to ActiveStorage blob URL with attachment disposition.
    assert_response :redirect
    assert_match(/blob/i, response.location)
  end

  test "download logs a security audit entry" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export")
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user",
      expires_at: 1.day.from_now,
    )
    export.file.attach(io: StringIO.new("zip"), filename: "x.zip", content_type: "application/zip")

    recorded = []
    SecurityAuditLog.stub(:log_user_action, ->(**kw) { recorded << kw }) do
      get "/u/#{@user_handle}/settings/data-export/#{export.id}"
    end
    assert recorded.any? { |r| r[:action] == "user_data_export_downloaded" && r[:user] == @user }
  end

  test "download refuses someone else's export by id" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export")
    not_mine = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @other_user,
      status: "completed", export_type: "user",
      expires_at: 1.day.from_now,
    )
    not_mine.file.attach(io: StringIO.new("zip"), filename: "x.zip", content_type: "application/zip")

    get "/u/#{@user_handle}/settings/data-export/#{not_mine.id}"
    assert_response :not_found
  end

  test "download refuses expired exports" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user_handle}/settings/data-export")
    expired = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user",
      expires_at: 1.day.ago,
    )
    expired.file.attach(io: StringIO.new("zip"), filename: "x.zip", content_type: "application/zip")

    get "/u/#{@user_handle}/settings/data-export/#{expired.id}"
    assert_redirected_to "/u/#{@user_handle}/settings/data-export"
    assert_match(/expired/i, flash[:alert])
  end
end
