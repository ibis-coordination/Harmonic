require "test_helper"

class SuperagentTest < ActiveSupport::TestCase
  # Helper methods to create common test objects
  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test Person", user_type: "person")
    User.create!(email: email, name: name, user_type: user_type)
  end

  test "Superagent.create works" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: 'Test Studio',
      handle: 'test',
    )
    assert superagent.persisted?
    assert_equal 'Test Tenant', superagent.tenant.name
    assert_equal 'Test Person', superagent.created_by.name
    assert_equal 'Test Studio', superagent.name
    assert_equal 'test', superagent.handle
  end

  test "Superagent.handle_is_valid validation" do
    tenant = create_tenant
    user = create_user
    begin
      superagent = Superagent.create!(
        tenant: tenant,
        created_by: user,
        name: "Invalid Handle Studio",
        handle: "invalid handle!" # Invalid handle
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match /handle must be alphanumeric with dashes/, e.message.downcase
    end
  end

  test "Superagent.creator_is_not_trustee validation" do
    tenant = create_tenant
    trustee_user = create_user(user_type: "trustee")
    begin
      superagent = Superagent.create!(
        tenant: tenant,
        created_by: trustee_user,
        name: "Trustee Studio",
        handle: "trustee-studio"
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match /created by cannot be a trustee/, e.message.downcase
    end
  end

  test "Superagent.set_defaults sets default settings" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Default Settings Studio",
      handle: "default-settings"
    )
    assert superagent.settings["unlisted"]
    assert superagent.settings["invite_only"]
    assert_equal "UTC", superagent.settings["timezone"]
    assert_equal "daily", superagent.settings["tempo"]
  end

  test "Superagent.handle_available? returns true for available handle" do
    assert Superagent.handle_available?("unique-handle")
  end

  test "Superagent.handle_available? returns false for taken handle" do
    tenant = create_tenant
    user = create_user
    Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Existing Studio",
      handle: "existing-handle"
    )
    assert_not Superagent.handle_available?("existing-handle")
  end

  test "Superagent.create_trustee! creates a trustee user" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Trustee Studio",
      handle: "trustee-studio"
    )
    assert superagent.trustee_user.present?
    assert_equal "trustee", superagent.trustee_user.user_type
  end

  test "Superagent.within_file_upload_limit? returns true when usage is below limit" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "File Upload Studio",
      handle: "file-upload"
    )
    assert superagent.within_file_upload_limit?
  end

  test "Superagent.add_user! adds a user to the superagent" do
    tenant = create_tenant
    user = create_user
    new_user = create_user(name: "New User")
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Team Studio",
      handle: "team-studio"
    )
    assert_not superagent.user_is_member?(new_user)
    superagent.add_user!(new_user)
    assert superagent.user_is_member?(new_user)
  end

  test "Superagent.is_main_superagent? returns true for main superagent" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_superagent!(created_by: user)
    superagent = tenant.main_superagent
    assert superagent.is_main_superagent?
  end

  test "Superagent.is_main_superagent? returns false for non-main superagent" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Non-Main Studio",
      handle: "non-main-studio"
    )
    assert_not superagent.is_main_superagent?
  end

  # === Scene Tests ===

  test "Superagent can be created as a scene" do
    tenant = create_tenant
    user = create_user
    scene = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Test Scene",
      handle: "test-scene",
      superagent_type: "scene"
    )
    assert scene.is_scene?
    assert_equal "scene", scene.superagent_type
  end

  test "Superagent default type is superagent" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Default Type Studio",
      handle: "default-type"
    )
    assert_not superagent.is_scene?
  end

  test "Scene can be open or invite-only" do
    tenant = create_tenant
    user = create_user
    scene = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Open Scene",
      handle: "open-scene",
      superagent_type: "scene"
    )

    assert scene.scene_is_invite_only?
    assert_not scene.scene_is_open?

    scene.settings["open_scene"] = true
    scene.save!

    assert scene.scene_is_open?
    assert_not scene.scene_is_invite_only?
  end

  # === API Settings Tests ===

  test "Superagent.api_enabled? returns true for main superagent" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_superagent!(created_by: user)
    main_superagent = tenant.main_superagent

    assert main_superagent.api_enabled?
  end

  test "Superagent.api_enabled? returns false by default for non-main superagent" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "API Test Studio",
      handle: "api-test-studio"
    )

    assert_not superagent.api_enabled?
  end

  test "Superagent.enable_api! enables API for superagent" do
    tenant = create_tenant
    user = create_user
    # Enable API at tenant level first (required for cascade)
    tenant.set_feature_flag!("api", true)

    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Enable API Studio",
      handle: "enable-api-studio"
    )

    superagent.enable_api!
    assert superagent.api_enabled?
  end

  # === Tempo Tests ===

  test "Superagent.tempo returns default tempo" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Tempo Studio",
      handle: "tempo-studio"
    )

    assert_equal "daily", superagent.tempo
  end

  test "Superagent.tempo= sets tempo" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Tempo Change Studio",
      handle: "tempo-change-studio"
    )

    superagent.tempo = "weekly"
    superagent.save!
    assert_equal "weekly", superagent.tempo
  end

  # === Timezone Tests ===

  test "Superagent.timezone returns UTC by default" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Timezone Studio",
      handle: "timezone-studio"
    )

    assert_equal "UTC", superagent.timezone.name
  end

  # === Path Tests ===

  test "Superagent.path returns correct path for superagent" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Path Studio",
      handle: "path-studio"
    )

    assert_equal "/studios/path-studio", superagent.path
  end

  test "Superagent.path returns correct path for scene" do
    tenant = create_tenant
    user = create_user
    scene = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Path Scene",
      handle: "path-scene",
      superagent_type: "scene"
    )

    assert_equal "/scenes/path-scene", scene.path
  end

  # === API JSON Tests ===

  test "Superagent.api_json includes expected fields" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "API JSON Studio",
      handle: "api-json-studio"
    )

    json = superagent.api_json
    assert_equal superagent.id, json[:id]
    assert_equal superagent.name, json[:name]
    assert_equal superagent.handle, json[:handle]
    assert_equal superagent.timezone.name, json[:timezone]
    assert_equal superagent.tempo, json[:tempo]
  end

  # === Recent Activity Tests ===

  test "Superagent.recent_notes returns notes within time window" do
    tenant = create_tenant
    user = create_user
    superagent = Superagent.create!(
      tenant: tenant,
      created_by: user,
      name: "Recent Notes Studio",
      handle: "recent-notes-studio"
    )

    # Create a recent note
    note = Note.create!(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      updated_by: user,
      title: "Recent Note",
      text: "This is recent"
    )

    recent = superagent.recent_notes(time_window: 1.week)
    assert_includes recent, note
  end
end
