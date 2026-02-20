require "test_helper"

class CollectiveTest < ActiveSupport::TestCase
  # Helper methods to create common test objects
  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test Person", user_type: "human")
    User.create!(email: email, name: name, user_type: user_type)
  end

  test "Collective.create works" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Test Studio",
      handle: "test"
    )
    assert collective.persisted?
    assert_equal "Test Tenant", collective.tenant.name
    assert_equal "Test Person", collective.created_by.name
    assert_equal "Test Studio", collective.name
    assert_equal "test", collective.handle
  end

  test "Collective.handle_is_valid validation" do
    tenant = create_tenant
    user = create_user
    begin
      Collective.create!(
        tenant: tenant,
        created_by: user,
        name: "Invalid Handle Studio",
        handle: "invalid handle!" # Invalid handle
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match(/handle must be alphanumeric with dashes/, e.message.downcase)
    end
  end

  test "Collective.creator_is_not_collective_identity validation" do
    tenant = create_tenant
    identity_user = create_user(user_type: "collective_identity")
    begin
      Collective.create!(
        tenant: tenant,
        created_by: identity_user,
        name: "Proxy Studio",
        handle: "proxy-studio"
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match(/created by cannot be a collective identity/, e.message.downcase)
    end
  end

  test "Collective.set_defaults sets default settings" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Default Settings Studio",
      handle: "default-settings"
    )
    assert collective.settings["unlisted"]
    assert collective.settings["invite_only"]
    assert_equal "UTC", collective.settings["timezone"]
    assert_equal "daily", collective.settings["tempo"]
  end

  test "Collective.handle_available? returns true for available handle" do
    assert Collective.handle_available?("unique-handle")
  end

  test "Collective.handle_available? returns false for taken handle" do
    tenant = create_tenant
    user = create_user
    Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Existing Studio",
      handle: "existing-handle"
    )
    assert_not Collective.handle_available?("existing-handle")
  end

  test "Collective.create_identity_user! creates an identity user" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Proxy Studio",
      handle: "proxy-studio"
    )
    assert collective.identity_user.present?
    assert_equal "collective_identity", collective.identity_user.user_type
  end

  test "Collective.within_file_upload_limit? returns true when usage is below limit" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "File Upload Studio",
      handle: "file-upload"
    )
    assert collective.within_file_upload_limit?
  end

  test "Collective.add_user! adds a user to the collective" do
    tenant = create_tenant
    user = create_user
    new_user = create_user(name: "New User")
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Team Studio",
      handle: "team-studio"
    )
    assert_not collective.user_is_member?(new_user)
    collective.add_user!(new_user)
    assert collective.user_is_member?(new_user)
  end

  test "Collective.is_main_collective? returns true for main collective" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_collective!(created_by: user)
    collective = tenant.main_collective
    assert collective.is_main_collective?
  end

  test "Collective.is_main_collective? returns false for non-main collective" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Non-Main Studio",
      handle: "non-main-studio"
    )
    assert_not collective.is_main_collective?
  end

  # === Scene Tests ===

  test "Collective can be created as a scene" do
    tenant = create_tenant
    user = create_user
    scene = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Test Scene",
      handle: "test-scene",
      collective_type: "scene"
    )
    assert scene.is_scene?
    assert_equal "scene", scene.collective_type
  end

  test "Collective default type is collective" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Default Type Studio",
      handle: "default-type"
    )
    assert_not collective.is_scene?
  end

  test "Scene can be open or invite-only" do
    tenant = create_tenant
    user = create_user
    scene = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Open Scene",
      handle: "open-scene",
      collective_type: "scene"
    )

    assert scene.scene_is_invite_only?
    assert_not scene.scene_is_open?

    scene.settings["open_scene"] = true
    scene.save!

    assert scene.scene_is_open?
    assert_not scene.scene_is_invite_only?
  end

  # === API Settings Tests ===

  test "Collective.api_enabled? returns true for main collective" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_collective!(created_by: user)
    main_collective = tenant.main_collective

    assert main_collective.api_enabled?
  end

  test "Collective.api_enabled? returns false by default for non-main collective" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "API Test Studio",
      handle: "api-test-studio"
    )

    assert_not collective.api_enabled?
  end

  test "Collective.enable_api! enables API for collective" do
    tenant = create_tenant
    user = create_user
    # Enable API at tenant level first (required for cascade)
    tenant.set_feature_flag!("api", true)

    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Enable API Studio",
      handle: "enable-api-studio"
    )

    collective.enable_api!
    assert collective.api_enabled?
  end

  # === Tempo Tests ===

  test "Collective.tempo returns default tempo" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Tempo Studio",
      handle: "tempo-studio"
    )

    assert_equal "daily", collective.tempo
  end

  test "Collective.tempo= sets tempo" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Tempo Change Studio",
      handle: "tempo-change-studio"
    )

    collective.tempo = "weekly"
    collective.save!
    assert_equal "weekly", collective.tempo
  end

  # === Timezone Tests ===

  test "Collective.timezone returns UTC by default" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Timezone Studio",
      handle: "timezone-studio"
    )

    assert_equal "UTC", collective.timezone.name
  end

  # === Path Tests ===

  test "Collective.path returns correct path for collective" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Path Studio",
      handle: "path-studio"
    )

    assert_equal "/studios/path-studio", collective.path
  end

  test "Collective.path returns correct path for scene" do
    tenant = create_tenant
    user = create_user
    scene = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Path Scene",
      handle: "path-scene",
      collective_type: "scene"
    )

    assert_equal "/scenes/path-scene", scene.path
  end

  # === API JSON Tests ===

  test "Collective.api_json includes expected fields" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "API JSON Studio",
      handle: "api-json-studio"
    )

    json = collective.api_json
    assert_equal collective.id, json[:id]
    assert_equal collective.name, json[:name]
    assert_equal collective.handle, json[:handle]
    assert_equal collective.timezone.name, json[:timezone]
    assert_equal collective.tempo, json[:tempo]
  end

  # === Recent Activity Tests ===

  test "Collective.recent_notes returns notes within time window" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Recent Notes Studio",
      handle: "recent-notes-studio"
    )

    # Create a recent note
    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Recent Note",
      text: "This is recent"
    )

    recent = collective.recent_notes(time_window: 1.week)
    assert_includes recent, note
  end

  # =========================================================================
  # accessible_by? tests
  # =========================================================================

  test "accessible_by? returns true for members" do
    tenant = create_tenant(subdomain: "accessible-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Access Test Studio",
      handle: "access-test-#{SecureRandom.hex(4)}"
    )
    collective.add_user!(user)

    assert collective.accessible_by?(user)
  end

  test "accessible_by? returns false for non-members" do
    tenant = create_tenant(subdomain: "accessible-#{SecureRandom.hex(4)}")
    user = create_user(name: "Owner User")
    other_user = create_user(name: "Other User")
    tenant.add_user!(user)
    tenant.add_user!(other_user)
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Access Test Studio",
      handle: "access-test-#{SecureRandom.hex(4)}"
    )
    collective.add_user!(user)
    # other_user is NOT added to collective

    assert_not collective.accessible_by?(other_user)
  end

  test "accessible_by? returns true for collective identity accessing own collective" do
    tenant = create_tenant(subdomain: "accessible-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Access Test Studio",
      handle: "access-test-#{SecureRandom.hex(4)}"
    )
    collective.add_user!(user)
    collective.create_identity_user!

    identity = collective.identity_user
    assert identity.identity_collective.present?
    assert collective.accessible_by?(identity)
  end

  test "accessible_by? returns false for collective identity accessing different collective" do
    tenant = create_tenant(subdomain: "accessible-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    collective1 = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Studio 1",
      handle: "studio-1-#{SecureRandom.hex(4)}"
    )
    collective1.add_user!(user)
    collective1.create_identity_user!

    collective2 = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Studio 2",
      handle: "studio-2-#{SecureRandom.hex(4)}"
    )
    collective2.add_user!(user)

    identity = collective1.identity_user
    assert identity.identity_collective.present?
    # Identity of collective1 should not have access to collective2
    assert_not collective2.accessible_by?(identity)
  end

  test "accessible_by? returns false for non-member even with trustee grant" do
    tenant = create_tenant(subdomain: "accessible-#{SecureRandom.hex(4)}")
    alice = create_user(name: "Alice")
    bob = create_user(name: "Bob")
    tenant.add_user!(alice)
    tenant.add_user!(bob)

    # Alice creates one studio she's a member of
    alices_studio = Collective.create!(
      tenant: tenant,
      created_by: alice,
      name: "Alice's Studio",
      handle: "alices-studio-#{SecureRandom.hex(4)}"
    )
    alices_studio.add_user!(alice)

    # Bob creates a studio that Alice is NOT a member of
    bobs_studio = Collective.create!(
      tenant: tenant,
      created_by: bob,
      name: "Bob's Studio",
      handle: "bobs-studio-#{SecureRandom.hex(4)}"
    )
    bobs_studio.add_user!(bob)

    grant = TrusteeGrant.create!(
      tenant: tenant,
      granting_user: alice,
      trustee_user: bob,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" }
    )
    grant.accept!

    trustee = grant.trustee_user
    assert_equal bob, trustee
    # Bob has access to his own studio (he's a member)
    assert bobs_studio.accessible_by?(trustee)
    # Bob does NOT have access to Alice's studio (he's not a member)
    assert_not alices_studio.accessible_by?(trustee)
  end
end
