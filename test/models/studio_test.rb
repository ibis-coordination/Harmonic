require "test_helper"

class StudioTest < ActiveSupport::TestCase
  # Helper methods to create common test objects
  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test Person", user_type: "person")
    User.create!(email: email, name: name, user_type: user_type)
  end

  test "Studio.create works" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: 'Test Studio',
      handle: 'test',
    )
    assert studio.persisted?
    assert_equal 'Test Tenant', studio.tenant.name
    assert_equal 'Test Person', studio.created_by.name
    assert_equal 'Test Studio', studio.name
    assert_equal 'test', studio.handle
  end

  test "Studio.handle_is_valid validation" do
    tenant = create_tenant
    user = create_user
    begin
      studio = Studio.create!(
        tenant: tenant,
        created_by: user,
        name: "Invalid Handle Studio",
        handle: "invalid handle!" # Invalid handle
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match /handle must be alphanumeric with dashes/, e.message.downcase
    end
  end

  test "Studio.creator_is_not_trustee validation" do
    tenant = create_tenant
    trustee_user = create_user(user_type: "trustee")
    begin
      studio = Studio.create!(
        tenant: tenant,
        created_by: trustee_user,
        name: "Trustee Studio",
        handle: "trustee-studio"
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match /created by cannot be a trustee/, e.message.downcase
    end
  end

  test "Studio.set_defaults sets default settings" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Default Settings Studio",
      handle: "default-settings"
    )
    assert studio.settings["unlisted"]
    assert studio.settings["invite_only"]
    assert_equal "UTC", studio.settings["timezone"]
    assert_equal "daily", studio.settings["tempo"]
  end

  test "Studio.handle_available? returns true for available handle" do
    assert Studio.handle_available?("unique-handle")
  end

  test "Studio.handle_available? returns false for taken handle" do
    tenant = create_tenant
    user = create_user
    Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Existing Studio",
      handle: "existing-handle"
    )
    assert_not Studio.handle_available?("existing-handle")
  end

  test "Studio.create_trustee! creates a trustee user" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Trustee Studio",
      handle: "trustee-studio"
    )
    assert studio.trustee_user.present?
    assert_equal "trustee", studio.trustee_user.user_type
  end

  test "Studio.within_file_upload_limit? returns true when usage is below limit" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "File Upload Studio",
      handle: "file-upload"
    )
    assert studio.within_file_upload_limit?
  end

  test "Studio.add_user! adds a user to the studio" do
    tenant = create_tenant
    user = create_user
    new_user = create_user(name: "New User")
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Team Studio",
      handle: "team-studio"
    )
    assert_not studio.user_is_member?(new_user)
    studio.add_user!(new_user)
    assert studio.user_is_member?(new_user)
  end

  test "Studio.is_main_studio? returns true for main studio" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_studio!(created_by: user)
    studio = tenant.main_studio
    assert studio.is_main_studio?
  end

  test "Studio.is_main_studio? returns false for non-main studio" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Non-Main Studio",
      handle: "non-main-studio"
    )
    assert_not studio.is_main_studio?
  end

  # === Scene Tests ===

  test "Studio can be created as a scene" do
    tenant = create_tenant
    user = create_user
    scene = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Test Scene",
      handle: "test-scene",
      studio_type: "scene"
    )
    assert scene.is_scene?
    assert_equal "scene", scene.studio_type
  end

  test "Studio default type is studio" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Default Type Studio",
      handle: "default-type"
    )
    assert_not studio.is_scene?
  end

  test "Scene can be open or invite-only" do
    tenant = create_tenant
    user = create_user
    scene = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Open Scene",
      handle: "open-scene",
      studio_type: "scene"
    )

    assert scene.scene_is_invite_only?
    assert_not scene.scene_is_open?

    scene.settings["open_scene"] = true
    scene.save!

    assert scene.scene_is_open?
    assert_not scene.scene_is_invite_only?
  end

  # === API Settings Tests ===

  test "Studio.api_enabled? returns true for main studio" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_studio!(created_by: user)
    main_studio = tenant.main_studio

    assert main_studio.api_enabled?
  end

  test "Studio.api_enabled? returns false by default for non-main studio" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "API Test Studio",
      handle: "api-test-studio"
    )

    assert_not studio.api_enabled?
  end

  test "Studio.enable_api! enables API for studio" do
    tenant = create_tenant
    user = create_user
    # Enable API at tenant level first (required for cascade)
    tenant.set_feature_flag!("api", true)

    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Enable API Studio",
      handle: "enable-api-studio"
    )

    studio.enable_api!
    assert studio.api_enabled?
  end

  # === Tempo Tests ===

  test "Studio.tempo returns default tempo" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Tempo Studio",
      handle: "tempo-studio"
    )

    assert_equal "daily", studio.tempo
  end

  test "Studio.tempo= sets tempo" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Tempo Change Studio",
      handle: "tempo-change-studio"
    )

    studio.tempo = "weekly"
    studio.save!
    assert_equal "weekly", studio.tempo
  end

  # === Timezone Tests ===

  test "Studio.timezone returns UTC by default" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Timezone Studio",
      handle: "timezone-studio"
    )

    assert_equal "UTC", studio.timezone.name
  end

  # === Path Tests ===

  test "Studio.path returns correct path for studio" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Path Studio",
      handle: "path-studio"
    )

    assert_equal "/studios/path-studio", studio.path
  end

  test "Studio.path returns correct path for scene" do
    tenant = create_tenant
    user = create_user
    scene = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Path Scene",
      handle: "path-scene",
      studio_type: "scene"
    )

    assert_equal "/scenes/path-scene", scene.path
  end

  # === API JSON Tests ===

  test "Studio.api_json includes expected fields" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "API JSON Studio",
      handle: "api-json-studio"
    )

    json = studio.api_json
    assert_equal studio.id, json[:id]
    assert_equal studio.name, json[:name]
    assert_equal studio.handle, json[:handle]
    assert_equal studio.timezone.name, json[:timezone]
    assert_equal studio.tempo, json[:tempo]
  end

  # === Recent Activity Tests ===

  test "Studio.recent_notes returns notes within time window" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Recent Notes Studio",
      handle: "recent-notes-studio"
    )

    # Create a recent note
    note = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Recent Note",
      text: "This is recent"
    )

    recent = studio.recent_notes(time_window: 1.week)
    assert_includes recent, note
  end
end
