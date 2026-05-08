# typed: false

require "test_helper"

class CollectiveDataTransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @admin_user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)

    # Make the user an admin of the collective
    member = @collective.collective_members.find_by(user_id: @admin_user.id)
    member.add_role!("admin")

    # Create a non-admin user
    @non_admin_user = create_user(name: "Non-Admin")
    @tenant.add_user!(@non_admin_user)
    @collective.add_user!(@non_admin_user)

    @temp_files = []

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  teardown do
    @temp_files&.each { |f| FileUtils.rm_f(f) }
  end

  # === Authorization: admin required ===

  test "non-admin user is redirected from exports index" do
    sign_in_as(@non_admin_user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/exports"
    assert_response :redirect
    assert_equal "You must be an admin to access data transfers.", flash[:alert]
  end

  test "non-admin user is redirected from create export" do
    sign_in_as(@non_admin_user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/exports"
    assert_response :redirect
    assert_equal "You must be an admin to access data transfers.", flash[:alert]
  end

  test "non-admin user is redirected from import form" do
    sign_in_as(@non_admin_user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/imports/new"
    assert_response :redirect
    assert_equal "You must be an admin to access data transfers.", flash[:alert]
  end

  test "unauthenticated user is redirected to login" do
    get "/collectives/#{@collective.handle}/exports"
    assert_redirected_to "/login"
  end

  test "non-admin with 2FA still rejected before reverification check" do
    # Proves require_admin runs before require_reverification.
    # If the order were reversed, this user would be redirected to /reverify
    # instead of getting the admin rejection.
    identity = @non_admin_user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!
    sign_in_as(@non_admin_user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/exports"
    assert_response :redirect
    assert_equal "You must be an admin to access data transfers.", flash[:alert]
  end

  test "admin without 2FA is redirected to 2FA setup" do
    sign_in_as(@admin_user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/exports"
    assert_redirected_to "/settings/two-factor"
  end

  test "admin with 2FA but without reverification is redirected to reverify" do
    sign_in_as(@admin_user, tenant: @tenant)
    # Set up 2FA but don't complete reverification
    identity = @admin_user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!

    get "/collectives/#{@collective.handle}/exports"
    assert_redirected_to "/reverify"
  end

  test "admin with completed reverification can access exports index" do
    sign_in_with_reverification(@admin_user, tenant: @tenant, path: "/collectives/#{@collective.handle}/exports")
    get "/collectives/#{@collective.handle}/exports"
    assert_response :success
  end

  test "POST create_export without reverification is redirected" do
    sign_in_as(@admin_user, tenant: @tenant)
    identity = @admin_user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret! unless identity.otp_enabled
    identity.enable_otp! unless identity.otp_enabled

    post "/collectives/#{@collective.handle}/exports"
    assert_redirected_to "/reverify"
  end

  test "POST create_import without reverification is redirected" do
    sign_in_as(@admin_user, tenant: @tenant)
    identity = @admin_user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret! unless identity.otp_enabled
    identity.enable_otp! unless identity.otp_enabled

    post "/collectives/#{@collective.handle}/imports", params: { file: "anything" }
    assert_redirected_to "/reverify"
  end

  # === Export flow ===

  test "admin can trigger an export" do
    sign_in_admin_with_reverification

    assert_enqueued_jobs 1, only: CollectiveExportJob do
      post "/collectives/#{@collective.handle}/exports"
    end

    assert_response :redirect
    assert_equal "Your export is being prepared. This page will update when it's ready.", flash[:notice]

    export = DataExport.last
    assert_equal "pending", export.status
    assert_equal @admin_user.id, export.user_id
    assert_equal @collective.id, export.collective_id
  end

  test "concurrent export is rejected" do
    sign_in_admin_with_reverification

    # Create an active export
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    DataExport.create!(tenant: @tenant, collective: @collective, user: @admin_user, status: "processing")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/exports"
    assert_response :redirect
    assert_equal "An export is already in progress for this collective.", flash[:alert]
  end

  test "download export redirects to blob for completed export" do
    sign_in_admin_with_reverification

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    export = DataExport.create!(tenant: @tenant, collective: @collective, user: @admin_user, status: "pending")
    CollectiveExportService.new(data_export: export).perform!
    export.reload
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/exports/#{export.id}"
    assert_response :redirect
    assert response.location.include?("rails/active_storage"), "Should redirect to ActiveStorage blob"
  end

  test "download expired export shows alert" do
    sign_in_admin_with_reverification

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    export = DataExport.create!(tenant: @tenant, collective: @collective, user: @admin_user, status: "pending")
    CollectiveExportService.new(data_export: export).perform!
    export.update_columns(expires_at: 1.day.ago)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/exports/#{export.id}"
    assert_response :redirect
    assert_equal "This export has expired.", flash[:alert]
  end

  # === Cross-collective scoping ===

  test "cannot download export from another collective" do
    sign_in_admin_with_reverification

    # Create an export in a different collective
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    other_collective = Collective.create!(tenant: @tenant, created_by: @admin_user, name: "Other", handle: "other-#{SecureRandom.hex(4)}")
    other_collective.add_user!(@admin_user)
    Collective.set_thread_context(other_collective)
    other_export = DataExport.create!(tenant: @tenant, collective: other_collective, user: @admin_user, status: "pending")
    CollectiveExportService.new(data_export: other_export).perform!
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # Try to download it from @collective's URL
    assert_raises(ActiveRecord::RecordNotFound) do
      get "/collectives/#{@collective.handle}/exports/#{other_export.id}"
    end
  end

  test "cannot view import from another user" do
    sign_in_admin_with_reverification

    # Create an import by a different user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    other_admin = create_user(name: "Other Admin")
    @tenant.add_user!(other_admin)
    @collective.add_user!(other_admin)
    @collective.collective_members.find_by(user_id: other_admin.id).add_role!("admin")
    other_import = DataImport.create!(tenant: @tenant, user: other_admin, status: "completed")
    Tenant.clear_thread_scope

    assert_raises(ActiveRecord::RecordNotFound) do
      get "/collectives/#{@collective.handle}/imports/#{other_import.id}"
    end
  end

  # === Import flow ===

  test "admin can access import form" do
    sign_in_admin_with_reverification
    get "/collectives/#{@collective.handle}/imports/new"
    assert_response :success
  end

  test "import without file shows alert" do
    sign_in_admin_with_reverification
    post "/collectives/#{@collective.handle}/imports"
    assert_response :redirect
    assert_equal "Please select a ZIP file to import.", flash[:alert]
  end

  test "import with file enqueues job" do
    sign_in_admin_with_reverification

    file = fixture_file_upload(create_minimal_export_zip, "application/zip")

    assert_enqueued_jobs 1, only: CollectiveImportJob do
      post "/collectives/#{@collective.handle}/imports", params: { file: file }
    end

    assert_response :redirect
    assert_equal "Your import is being processed. This page will update when it's complete.", flash[:notice]
  end

  private

  # Signs in the admin user and completes reverification for the "data_transfer" scope.
  # The scope is shared across all data transfer actions (exports + imports), so
  # reverifying once via the exports path grants access to all actions within the timeout.
  def sign_in_admin_with_reverification
    exports_path = "/collectives/#{@collective.handle}/exports"
    sign_in_with_reverification(@admin_user, tenant: @tenant, path: exports_path)
  end

  # Create a minimal valid export ZIP for testing the import controller action.
  # Registers the temp file for cleanup after the test.
  def create_minimal_export_zip
    require "zip"
    path = Rails.root.join("tmp", "test-import-#{SecureRandom.hex(4)}.zip")
    Zip::OutputStream.open(path.to_s) do |zos|
      zos.put_next_entry("export/manifest.json")
      zos.write(JSON.generate({
        "format_version" => "1.0",
        "app_version" => "1.14.0",
        "exported_at" => Time.current.iso8601,
        "source_instance" => "test",
        "collective" => { "name" => "Test", "handle" => "test" },
        "record_counts" => {},
        "checksums" => {},
      }))
      %w[collective.json users.json members.json notes.json decisions.json options.json
         decision_participants.json votes.json decision_audit_entries.json commitments.json
         commitment_participants.json links.json note_history_events.json].each do |f|
        zos.put_next_entry("export/#{f}")
        zos.write(f == "collective.json" ? JSON.generate({
          "source_id" => SecureRandom.uuid, "name" => "Test", "handle" => "test-import-#{SecureRandom.hex(4)}",
          "collective_type" => "standard", "settings" => {}, "source_created_by_id" => nil,
          "created_at" => Time.current.iso8601, "updated_at" => Time.current.iso8601,
        }) : "[]")
      end
    end
    @temp_files << path.to_s
    path.to_s
  end
end
