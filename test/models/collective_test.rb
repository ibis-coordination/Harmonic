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
      name: "Test Collective",
      handle: "test"
    )
    assert collective.persisted?
    assert_equal "Test Tenant", collective.tenant.name
    assert_equal "Test Person", collective.created_by.name
    assert_equal "Test Collective", collective.name
    assert_equal "test", collective.handle
  end

  test "Collective.handle_is_valid validation" do
    tenant = create_tenant
    user = create_user
    begin
      Collective.create!(
        tenant: tenant,
        created_by: user,
        name: "Invalid Handle Collective",
        handle: "invalid handle!" # Invalid handle
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match(/handle must be alphanumeric with dashes/, e.message.downcase)
    end
  end

  test "Collective rejects reserved handle 'main'" do
    tenant = create_tenant
    user = create_user
    error = assert_raises(ActiveRecord::RecordInvalid) do
      Collective.create!(
        tenant: tenant,
        created_by: user,
        name: "Main Collective",
        handle: "main"
      )
    end
    assert_match(/handle is reserved/i, error.message)
  end

  test "Collective.creator_is_not_collective_identity validation" do
    tenant = create_tenant
    identity_user = create_user(user_type: "collective_identity")
    begin
      Collective.create!(
        tenant: tenant,
        created_by: identity_user,
        name: "Proxy Collective",
        handle: "proxy-collective"
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
      name: "Default Settings Collective",
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

  test "Collective.handle_available? returns false for reserved handle" do
    assert_not Collective.handle_available?("main")
  end

  test "Collective.handle_available? returns false for taken handle" do
    tenant = create_tenant
    user = create_user
    Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Existing Collective",
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
      name: "Proxy Collective",
      handle: "proxy-collective"
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
      name: "File Upload Collective",
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
      name: "Team Collective",
      handle: "team-collective"
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
      name: "Non-Main Collective",
      handle: "non-main-collective"
    )
    assert_not collective.is_main_collective?
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
      name: "API Test Collective",
      handle: "api-test-collective"
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
      name: "Enable API Collective",
      handle: "enable-api-collective"
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
      name: "Tempo Collective",
      handle: "tempo-collective"
    )

    assert_equal "daily", collective.tempo
  end

  test "Collective.tempo= sets tempo" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Tempo Change Collective",
      handle: "tempo-change-collective"
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
      name: "Timezone Collective",
      handle: "timezone-collective"
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
      name: "Path Collective",
      handle: "path-collective"
    )

    assert_equal "/collectives/path-collective", collective.path
  end

  # === API JSON Tests ===

  test "Collective.api_json includes expected fields" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "API JSON Collective",
      handle: "api-json-collective"
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
      name: "Recent Notes Collective",
      handle: "recent-notes-collective"
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
      name: "Access Test Collective",
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
      name: "Access Test Collective",
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
      name: "Access Test Collective",
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
      name: "Collective 1",
      handle: "collective-1-#{SecureRandom.hex(4)}"
    )
    collective1.add_user!(user)
    collective1.create_identity_user!

    collective2 = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Collective 2",
      handle: "collective-2-#{SecureRandom.hex(4)}"
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

    # Alice creates one collective she's a member of
    alices_collective = Collective.create!(
      tenant: tenant,
      created_by: alice,
      name: "Alice's Collective",
      handle: "alices-collective-#{SecureRandom.hex(4)}"
    )
    alices_collective.add_user!(alice)

    # Bob creates a collective that Alice is NOT a member of
    bobs_collective = Collective.create!(
      tenant: tenant,
      created_by: bob,
      name: "Bob's Collective",
      handle: "bobs-collective-#{SecureRandom.hex(4)}"
    )
    bobs_collective.add_user!(bob)

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
    # Bob has access to his own collective (he's a member)
    assert bobs_collective.accessible_by?(trustee)
    # Bob does NOT have access to Alice's collective (he's not a member)
    assert_not alices_collective.accessible_by?(trustee)
  end

  # === Archive Tests ===

  test "archive! sets archived_at" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Archive Test", handle: "archive-test-#{SecureRandom.hex(4)}")

    assert_nil collective.archived_at
    collective.archive!
    assert collective.archived?
    assert_not_nil collective.archived_at
  end

  test "unarchive! clears archived_at" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Unarchive Test", handle: "unarchive-test-#{SecureRandom.hex(4)}")

    collective.archive!
    assert collective.archived?
    collective.unarchive!
    assert_not collective.archived?
    assert_nil collective.archived_at
  end

  test "archive! disables automation rules" do
    tenant = create_tenant
    user = create_user
    tenant.add_user!(user)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Auto Test", handle: "auto-test-#{SecureRandom.hex(4)}")
    collective.add_user!(user)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create an enabled automation rule
    rule = AutomationRule.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      name: "Test Rule",
      trigger_type: "webhook",
      actions: { "type" => "webhook", "url" => "https://example.com/hook" },
      enabled: true,
    )

    collective.archive!

    rule.reload
    assert_not rule.enabled?, "Automation rule should be disabled after collective is archived"

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "unarchive! does not re-enable automation rules" do
    tenant = create_tenant
    user = create_user
    tenant.add_user!(user)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    collective = Collective.create!(tenant: tenant, created_by: user, name: "NoReEnable Test", handle: "nore-test-#{SecureRandom.hex(4)}")
    collective.add_user!(user)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    agent = create_ai_agent(parent: user, name: "NoRe Agent #{SecureRandom.hex(4)}")
    tenant.add_user!(agent)
    collective.add_user!(agent)
    rule = AutomationRule.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      name: "Test Rule",
      trigger_type: "webhook",
      actions: { "type" => "webhook", "url" => "https://example.com/hook" },
      enabled: true,
    )

    collective.archive!
    collective.unarchive!

    rule.reload
    assert_not rule.enabled?, "Automation rule should NOT be re-enabled after unarchive"

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # =========================================================================
  # Private Workspace tests
  # =========================================================================

  test "private_workspace? returns true for private_workspace collective_type" do
    tenant = create_tenant(subdomain: "pw-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    workspace = user.private_workspace
    assert workspace, "User should have a private workspace after being added to tenant"
    assert workspace.private_workspace?
  end

  test "private_workspace? returns false for standard collectives" do
    tenant = create_tenant(subdomain: "pw-std-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Standard Collective",
      handle: "standard-#{SecureRandom.hex(4)}",
    )
    assert_not collective.private_workspace?
  end

  test "private workspace has no identity user" do
    tenant = create_tenant(subdomain: "pw-ident-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    workspace = user.private_workspace
    assert_nil workspace.identity_user
  end

  test "standard collective has identity user" do
    tenant = create_tenant(subdomain: "pw-std-id-#{SecureRandom.hex(4)}")
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Identity Test",
      handle: "identity-test-#{SecureRandom.hex(4)}",
    )
    assert collective.identity_user.present?
    assert_equal "collective_identity", collective.identity_user.user_type
  end

  test "private workspace enforces settings" do
    tenant = create_tenant(subdomain: "pw-settings-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    workspace = user.private_workspace
    assert workspace.settings["unlisted"]
    assert workspace.settings["invite_only"]
    assert_not workspace.settings["all_members_can_invite"]
    assert_not workspace.settings["any_member_can_represent"]
  end

  test "private workspace is billing_exempt" do
    tenant = create_tenant(subdomain: "pw-billing-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    workspace = user.private_workspace
    assert workspace.billing_exempt?
  end

  test "collective_type cannot be changed after creation" do
    tenant = create_tenant(subdomain: "pw-immut-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    workspace = user.private_workspace
    workspace.collective_type = "standard"
    assert_raises(ActiveRecord::RecordInvalid) do
      workspace.save!
    end
    # Verify the workspace is still a private workspace in the DB
    workspace.reload
    assert workspace.private_workspace?
  end

  test "not_private_workspace scope excludes private workspaces" do
    tenant = create_tenant(subdomain: "pw-scope-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)
    Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Visible Collective",
      handle: "visible-#{SecureRandom.hex(4)}",
    )

    all = Collective.where(tenant_id: tenant.id)
    filtered = Collective.where(tenant_id: tenant.id).not_private_workspace

    # All includes the workspace + the standard collective + main (if any)
    assert all.count > filtered.count, "Unfiltered should include more collectives than filtered"
    assert filtered.where(collective_type: "private_workspace").count == 0
  end

  test "find_or_create_shareable_invite raises for private workspaces" do
    tenant = create_tenant(subdomain: "pw-invite-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    workspace = user.private_workspace
    assert_raises(RuntimeError, "Cannot create invites for private workspaces") do
      workspace.find_or_create_shareable_invite(user)
    end
  end

  test "add_user! raises when adding non-owner to private workspace" do
    tenant = create_tenant(subdomain: "pw-add-#{SecureRandom.hex(4)}")
    owner = create_user(name: "Owner")
    other = create_user(name: "Other")
    tenant.add_user!(owner)
    tenant.add_user!(other)

    workspace = owner.private_workspace
    assert workspace

    assert_raises(RuntimeError, "Cannot add other users to a private workspace") do
      workspace.add_user!(other)
    end
    assert_not workspace.user_is_member?(other)
  end

  test "add_user! allows re-adding owner to private workspace" do
    tenant = create_tenant(subdomain: "pw-readd-#{SecureRandom.hex(4)}")
    owner = create_user(name: "Owner")
    tenant.add_user!(owner)

    workspace = owner.private_workspace
    assert workspace
    assert workspace.user_is_member?(owner)

    # Re-adding the owner should not raise
    workspace.add_user!(owner, roles: ["admin"])
    assert workspace.user_is_member?(owner)
  end
end
