require "test_helper"

class TenantAdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    super
    # Create primary tenant
    @primary_tenant = create_tenant(subdomain: ENV["PRIMARY_SUBDOMAIN"] || "app", name: "Primary Tenant")
    @primary_user = create_user(email: "primary@example.com", name: "Primary User")
    @primary_tenant.add_user!(@primary_user)
    @primary_tenant.create_main_collective!(created_by: @primary_user)
    @primary_collective = @primary_tenant.main_collective
    @primary_collective.add_user!(@primary_user)

    # Create secondary tenant with admin user
    @secondary_tenant = create_tenant(subdomain: "secondary", name: "Secondary Tenant")
    @secondary_admin = create_user(email: "secondary_admin@example.com", name: "Secondary Admin")
    @secondary_tenant.add_user!(@secondary_admin)
    @secondary_tenant.create_main_collective!(created_by: @secondary_admin)
    @secondary_collective = @secondary_tenant.main_collective
    @secondary_collective.add_user!(@secondary_admin)
    # Make them a tenant admin
    @secondary_tenant_user = @secondary_tenant.tenant_users.find_by(user: @secondary_admin)
    @secondary_tenant_user.add_role!("admin")

    # Create tenant admin user on primary tenant
    @tenant_admin_user = create_user(email: "tenant_admin@example.com", name: "Tenant Admin User")
    @primary_tenant.add_user!(@tenant_admin_user)
    @primary_collective.add_user!(@tenant_admin_user)
    # Make them a tenant admin
    @primary_tenant_user = @primary_tenant.tenant_users.find_by(user: @tenant_admin_user)
    @primary_tenant_user.add_role!("admin")

    # Create a regular non-admin user on primary tenant
    @non_admin_user = create_user(email: "non_admin@example.com", name: "Non Admin User")
    @primary_tenant.add_user!(@non_admin_user)
    @primary_collective.add_user!(@non_admin_user)
    @non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)
  end

  # ==========================================
  # Dashboard Tests
  # ==========================================

  test "tenant admin can access dashboard on primary tenant" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin"

    assert_response :success
    assert_select "h1", /Tenant Admin/
  end

  test "tenant admin can access dashboard on secondary tenant" do
    sign_in_as_admin(@secondary_admin, tenant: @secondary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin"

    assert_response :success
    assert_select "h1", /Tenant Admin/
  end

  test "non-admin cannot access tenant admin dashboard" do
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/tenant-admin"

    assert_response :forbidden
    assert_select "h1", /Access Denied/
  end

  # ==========================================
  # Settings Tests
  # ==========================================

  test "tenant admin can view settings" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/settings"

    assert_response :success
    assert_select "h1", /Tenant Settings/
  end

  test "tenant admin can update settings" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    post "/tenant-admin/settings", params: { name: "Updated Tenant Name" }

    assert_response :redirect
    @primary_tenant.reload
    assert_equal "Updated Tenant Name", @primary_tenant.name
  end

  test "tenant admin can update allowed attachment categories" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    # Form posts the hidden empty marker plus only the categories the admin
    # left checked. Here only "images" and "pdfs" are checked; "text" is not.
    post "/tenant-admin/settings", params: {
      allowed_attachment_categories: ["", "images", "pdfs"],
    }

    assert_response :redirect
    @primary_tenant.reload
    assert_equal ["images", "pdfs"], @primary_tenant.allowed_attachment_categories
  end

  test "tenant admin can disable all attachment categories" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    # Hidden empty marker only — no boxes checked.
    post "/tenant-admin/settings", params: {
      allowed_attachment_categories: [""],
    }

    assert_response :redirect
    @primary_tenant.reload
    assert_equal [], @primary_tenant.allowed_attachment_categories
  end

  test "tenant admin settings update ignores unknown attachment categories" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    post "/tenant-admin/settings", params: {
      allowed_attachment_categories: ["", "images", "audio", "executables"],
    }

    assert_response :redirect
    @primary_tenant.reload
    assert_equal ["images"], @primary_tenant.allowed_attachment_categories
  end

  # ==========================================
  # Users Tests
  # ==========================================

  test "tenant admin can view users list" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/users"

    assert_response :success
    assert_select "h1", /Users/
  end

  test "tenant admin can search users by email" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/users", params: { q: @non_admin_user.email }

    assert_response :success
  end

  test "tenant admin user search escapes LIKE wildcards" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    # Verify that a normal search finds users
    get "/tenant-admin/users", params: { q: "non_admin" }
    assert_response :success
    assert_select "code", text: /non_admin@example\.com/

    # "%" as a search query should NOT match any users — LIKE wildcards must be escaped
    get "/tenant-admin/users", params: { q: "%" }
    assert_response :success
    assert_select "code", { text: /non_admin@example\.com/, count: 0 },
                  "Query '%' should not match users via LIKE wildcard injection"
  end

  test "tenant admin can view user details by handle" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/users/#{@non_admin_tenant_user.handle}"

    assert_response :success
    assert_select "h1", /#{@non_admin_user.display_name || @non_admin_user.name}/
  end

  # ==========================================
  # User Suspension Tests (Tenant admins should NOT have suspend/unsuspend)
  # ==========================================

  # suspend_user / unsuspend_user are app-admin actions; they only exist at
  # /admin/users/:handle. Posting them to /tenant-admin/users/:handle hits
  # the unknown-action catch-all, which returns 404 (markdown clients also
  # get the available-actions list for the path; HTML clients just see the
  # status). These tests use the default HTML format, so we only check the
  # status.

  test "tenant admin cannot access suspend user route (only app admins can suspend)" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    post "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/suspend_user", params: { reason: "Test suspension" }
    assert_response :not_found
  end

  test "tenant admin cannot access unsuspend user route (only app admins can unsuspend)" do
    @non_admin_user.update!(suspended_at: Time.current, suspended_reason: "Test")
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    post "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/unsuspend_user"
    assert_response :not_found
  end

  test "tenant admin cannot access describe suspend user route" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/suspend_user"
    assert_response :not_found
  end

  test "tenant admin cannot access describe unsuspend user route" do
    @non_admin_user.update!(suspended_at: Time.current, suspended_reason: "Test")
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/unsuspend_user"
    assert_response :not_found
  end

  # ==========================================
  # Markdown Format Tests
  # ==========================================

  test "tenant admin dashboard responds to markdown format" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# Tenant Admin/, response.body)
  end

  test "settings responds to markdown format" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/settings", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# Tenant Settings/, response.body)
  end

  test "users list responds to markdown format" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/users", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# Users/, response.body)
  end

  test "user show responds to markdown format" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")

    get "/tenant-admin/users/#{@non_admin_tenant_user.handle}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/Back to All Users/, response.body)
  end

  # ==========================================
  # Data Import Tests
  # ==========================================

  test "non-admin cannot access imports index" do
    sign_in_as(@non_admin_user, tenant: @primary_tenant)
    get "/tenant-admin/imports"
    assert_response :forbidden
  end

  test "tenant admin can access imports index" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")
    get "/tenant-admin/imports"
    assert_response :success
  end

  test "tenant admin can access new import form" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")
    get "/tenant-admin/imports/new"
    assert_response :success
  end

  test "tenant admin can create import" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")

    file = fixture_file_upload(create_minimal_export_zip, "application/zip")

    assert_enqueued_jobs 1, only: CollectiveImportJob do
      post "/tenant-admin/imports", params: { file: file }
    end

    assert_response :redirect
    assert_equal "Your import is being processed. This page will update when it's complete.", flash[:notice]
  end

  test "import without file shows alert" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")
    post "/tenant-admin/imports"
    assert_response :redirect
    assert_equal "Please select a ZIP file to import.", flash[:alert]
  end

  test "import rejects non-zip file" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")

    path = Rails.root.join("tmp", "test-not-a-zip-#{SecureRandom.hex(4)}.txt")
    File.write(path, "this is not a zip file")
    @temp_files ||= []
    @temp_files << path.to_s

    file = fixture_file_upload(path.to_s, "application/zip")

    assert_no_enqueued_jobs only: CollectiveImportJob do
      post "/tenant-admin/imports", params: { file: file }
    end

    assert_response :redirect
    assert_equal "File must be a valid ZIP archive.", flash[:alert]
  end

  test "import stores use_placeholders and handle_email_map options" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")

    map_path = Rails.root.join("tmp", "test-user-map-#{SecureRandom.hex(4)}.json")
    File.write(map_path, JSON.generate({ "alice" => "alice@example.com", "bob" => "bob@example.com" }))
    @temp_files ||= []
    @temp_files << map_path.to_s

    zip = fixture_file_upload(create_minimal_export_zip, "application/zip")
    map = fixture_file_upload(map_path.to_s, "application/json")

    post "/tenant-admin/imports", params: { file: zip, user_map: map, use_placeholders: "1" }

    import = DataImport.where(tenant_id: @primary_tenant.id).order(created_at: :desc).first
    assert_equal true, import.import_options["use_placeholders"]
    assert_equal({ "alice" => "alice@example.com", "bob" => "bob@example.com" }, import.import_options["handle_email_map"])
  end

  test "import rejects malformed user_map JSON" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")

    map_path = Rails.root.join("tmp", "test-bad-map-#{SecureRandom.hex(4)}.json")
    File.write(map_path, "{not valid json")
    @temp_files ||= []
    @temp_files << map_path.to_s

    zip = fixture_file_upload(create_minimal_export_zip, "application/zip")
    map = fixture_file_upload(map_path.to_s, "application/json")

    assert_no_enqueued_jobs only: CollectiveImportJob do
      post "/tenant-admin/imports", params: { file: zip, user_map: map }
    end

    assert_response :redirect
    assert_match(/User mapping file is not valid JSON/, flash[:alert])
  end

  test "import rejects user_map that is not handle→email object" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")

    map_path = Rails.root.join("tmp", "test-wrong-shape-#{SecureRandom.hex(4)}.json")
    File.write(map_path, JSON.generate(["alice@example.com", "bob@example.com"]))
    @temp_files ||= []
    @temp_files << map_path.to_s

    zip = fixture_file_upload(create_minimal_export_zip, "application/zip")
    map = fixture_file_upload(map_path.to_s, "application/json")

    assert_no_enqueued_jobs only: CollectiveImportJob do
      post "/tenant-admin/imports", params: { file: zip, user_map: map }
    end

    assert_response :redirect
    assert_match(/must be a JSON object/, flash[:alert])
  end

  test "import rejects when another import is already in progress" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")

    DataImport.create!(tenant: @primary_tenant, user: @tenant_admin_user, status: "importing")

    file = fixture_file_upload(create_minimal_export_zip, "application/zip")

    assert_no_enqueued_jobs only: CollectiveImportJob do
      post "/tenant-admin/imports", params: { file: file }
    end

    assert_response :redirect
    assert_equal "An import is already in progress for this tenant.", flash[:alert]
  end

  test "tenant admin can view import status" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")
    import = DataImport.create!(tenant: @primary_tenant, user: @tenant_admin_user, status: "completed")
    get "/tenant-admin/imports/#{import.id}"
    assert_response :success
  end

  test "tenant admin cannot view import from another tenant" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")
    other_import = DataImport.create!(tenant: @secondary_tenant, user: @secondary_admin, status: "completed")
    assert_raises(ActiveRecord::RecordNotFound) do
      get "/tenant-admin/imports/#{other_import.id}"
    end
  end

  test "imports index responds to markdown format" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")
    get "/tenant-admin/imports", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/# Data Imports/, response.body)
  end

  test "show import responds to markdown format" do
    sign_in_as_admin(@tenant_admin_user, tenant: @primary_tenant, admin_path: "/tenant-admin")
    import = DataImport.create!(tenant: @primary_tenant, user: @tenant_admin_user, status: "completed")
    get "/tenant-admin/imports/#{import.id}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/# Import Status/, response.body)
  end

  test "creating import logs to security audit" do
    sign_in_with_reverification(@tenant_admin_user, tenant: @primary_tenant, path: "/tenant-admin/imports/new")
    mark_audit_log_position

    file = fixture_file_upload(create_minimal_export_zip, "application/zip")
    post "/tenant-admin/imports", params: { file: file }

    entry = find_audit_entry("data_import_created")
    assert entry, "Expected data_import_created event in security audit log"
    assert_equal @tenant_admin_user.id, entry["user_id"]
  end

  private

  def mark_audit_log_position
    log_file = Rails.root.join("log/security_audit.log")
    @audit_log_offset = File.exist?(log_file) ? File.size(log_file) : 0
  end

  def find_audit_entry(admin_action)
    log_file = Rails.root.join("log/security_audit.log")
    return nil unless File.exist?(log_file)

    File.open(log_file) do |f|
      f.seek(@audit_log_offset || 0)
      f.each_line do |line|
        entry = JSON.parse(line) rescue next
        return entry if entry["admin_action"] == admin_action
      end
    end
    nil
  end

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
    @temp_files ||= []
    @temp_files << path.to_s
    path.to_s
  end
end
