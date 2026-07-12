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

  test "Collective rejects a cased variant of the reserved handle 'main'" do
    tenant = create_tenant
    user = create_user
    error = assert_raises(ActiveRecord::RecordInvalid) do
      Collective.create!(tenant: tenant, created_by: user, name: "Main Collective", handle: "Main")
    end
    assert_match(/handle is reserved/i, error.message)
  end

  test "Collective rejects group-tag handles so they can't shadow the tag" do
    tenant = create_tenant
    user = create_user
    ReservedHandles.group_tags.each do |tag|
      error = assert_raises(ActiveRecord::RecordInvalid, "#{tag} should be reserved") do
        Collective.create!(tenant: tenant, created_by: user, name: tag.capitalize, handle: tag)
      end
      assert_match(/handle is reserved/i, error.message)
    end
  end

  test "Collective.handle_available? returns false for group-tag handles" do
    ReservedHandles.group_tags.each do |tag|
      assert_not Collective.handle_available?(tag), "#{tag} must be unavailable"
      assert_not Collective.handle_available?(tag.upcase), "#{tag} check must be case-insensitive"
    end
  end

  test "Collective handle keeps the case the creator chose" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Foo Team", handle: "Foo-Team")
    assert_equal "Foo-Team", collective.handle, "display case must be preserved, not lowercased"
  end

  test "Collective handle uniqueness is case-insensitive within a tenant" do
    tenant = create_tenant
    user = create_user
    Collective.create!(tenant: tenant, created_by: user, name: "Foo Team", handle: "foo-team")

    # Collective handle uniqueness is enforced by the DB unique index, not a
    # model validation; with the citext column it now rejects cased variants.
    assert_raises(ActiveRecord::RecordNotUnique) do
      Collective.create!(tenant: tenant, created_by: user, name: "Foo Team Two", handle: "Foo-Team")
    end
    assert_not Collective.handle_available?("FOO-TEAM"), "availability check must be case-insensitive"
  end

  test "Collective is found regardless of the case its handle is looked up by" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Foo Team", handle: "Foo-Team")

    %w[foo-team FOO-TEAM Foo-Team].each do |variant|
      assert_equal collective.id, tenant.collectives.find_by(handle: variant)&.id,
                   "/collectives/#{variant} should resolve to the same collective"
    end
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

  test "Collective.handle_available? returns false when a user already holds the handle" do
    tenant = create_tenant
    user = create_user
    TenantUser.create!(tenant: tenant, user: user, display_name: "Squatter", handle: "shared-name")

    # Collective and user handles are one namespace (Goal 2): if a user already
    # holds "shared-name", the new-collective form must report it as taken so a
    # collective's identity user gets the identical handle rather than a suffixed
    # fallback. citext makes the cross-namespace check case-insensitive too.
    assert_not Collective.handle_available?("shared-name")
    assert_not Collective.handle_available?("SHARED-NAME"), "cross-namespace check must be case-insensitive"
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

  # Issue #477: a new collective's identity is born a first-class member of the
  # tenant's main collective, so it's counted in the directory and admissible to
  # the tenant-wide "everyone" list without any special-case exception.
  test "create_identity_user! joins the identity to the main collective (issue #477)" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_collective!(created_by: user)
    main = tenant.main_collective

    collective = Collective.create!(tenant: tenant, created_by: user, name: "Foo Team", handle: "foo-team")

    assert_includes main.member_users, collective.identity_user
  end

  # The main collective has no parent-of-the-parent to join, and counting its own
  # identity as its own member is meaningless — so it must not self-join.
  test "the main collective's own identity is not a member of the main collective (issue #477)" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_collective!(created_by: user)
    main = tenant.main_collective

    assert main.identity_user.present?
    assert_not_includes main.member_users, main.identity_user
  end

  # Goal 2 of handle-model-unification: the identity user shares the collective's
  # own handle so @foo-team and /collectives/foo-team resolve to one identity.
  test "identity user shares the collective's handle" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Foo Team", handle: "Foo-Team")
    identity_tu = TenantUser.tenant_scoped_only(tenant.id).find_by(user_id: collective.identity_user_id)
    assert_equal "Foo-Team", identity_tu.handle
  end

  test "identity user handle is suffixed when a user already holds the collective handle" do
    tenant = create_tenant
    user = create_user
    TenantUser.create!(tenant: tenant, user: create_user, display_name: "Squatter", handle: "foo-team")
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Foo Team", handle: "foo-team")
    identity_tu = TenantUser.tenant_scoped_only(tenant.id).find_by(user_id: collective.identity_user_id)
    assert_match(/\Afoo-team-[0-9a-f]{4}\z/, identity_tu.handle)
  end

  test "identity user handle is suffixed when the collective handle is reserved for system agents" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Trio", handle: "trio")
    identity_tu = TenantUser.tenant_scoped_only(tenant.id).find_by(user_id: collective.identity_user_id)
    assert_match(/\Atrio-[0-9a-f]{4}\z/, identity_tu.handle)
  end

  test "renaming the collective syncs the identity user handle" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Foo Team", handle: "foo-team")
    collective.update!(handle: "bar-team")
    identity_tu = TenantUser.tenant_scoped_only(tenant.id).find_by(user_id: collective.identity_user_id)
    assert_equal "bar-team", identity_tu.handle
  end

  test "Collective#trio_user is nil by default and links to a User when set" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Trio FK Collective",
      handle: "trio-fk-collective"
    )
    assert_nil collective.trio_user

    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio",
      user_type: "ai_agent",
      system_role: "trio",
      parent_id: nil
    )
    collective.update!(trio_user: trio)

    assert_equal trio.id, collective.reload.trio_user_id
    assert_equal trio, collective.trio_user
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

  test "Collective#file_storage_usage sums both Attachment and MediaItem byte_size" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Quota Collective",
      handle: "quota-collective-#{SecureRandom.hex(4)}"
    )
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.set_thread_context(collective)
    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Quota note",
      text: "x"
    )

    # Direct inserts avoid the full upload/blob lifecycle; we only need the
    # byte_size rows for this sum, not actual files.
    now = Time.current
    Attachment.insert!({
                         id: SecureRandom.uuid,
                         tenant_id: tenant.id,
                         collective_id: collective.id,
                         attachable_type: "Note",
                         attachable_id: note.id,
                         name: "a.txt",
                         content_type: "text/plain",
                         byte_size: 1_000,
                         created_by_id: user.id,
                         updated_by_id: user.id,
                         created_at: now,
                         updated_at: now,
                       })
    MediaItem.insert!({
                        id: SecureRandom.uuid,
                        tenant_id: tenant.id,
                        collective_id: collective.id,
                        mediable_type: "Note",
                        mediable_id: note.id,
                        content_type: "image/png",
                        byte_size: 2_500,
                        display_order: 0,
                        created_by_id: user.id,
                        updated_by_id: user.id,
                        created_at: now,
                        updated_at: now,
                      })

    assert_equal 3_500, collective.file_storage_usage
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  test "Collective#member_count returns active member count without instantiating records" do
    tenant = create_tenant(subdomain: "member-count-#{SecureRandom.hex(4)}")
    creator = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: creator,
      name: "Member Count",
      handle: "member-count-#{SecureRandom.hex(4)}",
    )
    collective.add_user!(creator)
    3.times { collective.add_user!(create_user(name: "MC #{SecureRandom.hex(4)}")) }
    archived = create_user(name: "Archived #{SecureRandom.hex(4)}")
    collective.add_user!(archived)
    collective.collective_members.find_by(user: archived).archive!
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)

    queries = []
    callback = ->(_name, _start, _finish, _id, payload) do
      sql = payload[:sql]
      next if payload[:name] == "SCHEMA" || sql.start_with?("BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE SAVEPOINT")
      queries << sql
    end
    count = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { count = collective.member_count }

    assert_equal 4, count, "creator + 3 added members; archived member excluded"
    assert(queries.any? { |q| q.start_with?("SELECT COUNT") && q.include?("collective_members") },
      "expected a COUNT query; got: #{queries.inspect}")
    refute(queries.any? { |q| q.start_with?("SELECT \"collective_members\".*") },
      "expected no SELECT * on collective_members; got: #{queries.inspect}")
  end

  test "Collective#team does not fire a CollectiveMember query per member" do
    tenant = create_tenant(subdomain: "team-nplus1-#{SecureRandom.hex(4)}")
    creator = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: creator,
      name: "Team N+1",
      handle: "team-nplus1-#{SecureRandom.hex(4)}",
    )
    5.times { collective.add_user!(create_user(name: "Member #{SecureRandom.hex(4)}")) }
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.set_thread_context(collective)

    queries = []
    callback = ->(_name, _start, _finish, _id, payload) do
      sql = payload[:sql]
      next if payload[:name] == "SCHEMA" || sql.start_with?("BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE SAVEPOINT")
      queries << sql
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { collective.team }

    member_lookups = queries.count { |q| q.include?("collective_members") && q.include?("user_id") && q.include?("LIMIT") }
    assert_equal 0, member_lookups,
      "Expected zero per-user CollectiveMember lookups in #team; got #{member_lookups}: #{queries.select { |q| q.include?('collective_members') }.inspect}"
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

  test "Collective.api_enabled? returns false for non-main collective when tenant API is disabled" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "API Test Collective",
      handle: "api-test-collective"
    )

    # Tenant API flag is off by default, which gates the collective regardless
    # of the collective-local default.
    assert_not collective.api_enabled?
  end

  test "Collective.api_enabled? is true by default for a new collective under an API-enabled tenant" do
    # Regression for #323: new collectives should inherit their tenant's
    # API-enabled posture rather than defaulting API off.
    tenant = create_tenant
    user = create_user
    tenant.set_feature_flag!("api", true)

    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Inherited API Collective",
      handle: "inherited-api-collective"
    )

    assert collective.api_enabled?, "New collective should default to API enabled when the tenant has API enabled"
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
      collective_scope: { "mode" => "all" }
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

  test "archive! sets archived_at and archived_by_id" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Archive Test", handle: "archive-test-#{SecureRandom.hex(4)}")

    assert_nil collective.archived_at
    assert_nil collective.archived_by_id
    collective.archive!(actor: user)
    assert collective.archived?
    assert_not_nil collective.archived_at
    assert_equal user.id, collective.archived_by_id,
                 "archive! must record who archived the collective"
  end

  test "archive! on an already-archived collective is a no-op (does not overwrite archived_at/archived_by_id)" do
    tenant = create_tenant
    owner = create_user
    other_owner_role_user = create_user
    collective = Collective.create!(tenant: tenant, created_by: owner, name: "Double Archive", handle: "double-arch-#{SecureRandom.hex(4)}")
    collective.archive!(actor: owner)
    original_at = collective.reload.archived_at
    original_by = collective.archived_by_id
    assert_not_nil original_at
    assert_equal owner.id, original_by

    # Even another legitimate call must not clobber the original archive metadata.
    travel 5.seconds do
      collective.archive!(actor: owner)
    end

    collective.reload
    assert_equal original_at, collective.archived_at,
                 "second archive! must not reset archived_at"
    assert_equal original_by, collective.archived_by_id,
                 "second archive! must not overwrite archived_by_id"
  end

  test "unarchive! on a non-archived collective is a no-op" do
    tenant = create_tenant
    owner = create_user
    collective = Collective.create!(tenant: tenant, created_by: owner, name: "Not Archived", handle: "not-arch-#{SecureRandom.hex(4)}")
    assert_not collective.archived?

    sync_calls = 0
    StripeService.stub(:sync_subscription_quantity!, ->(_) { sync_calls += 1; StripeService::SyncResult.new(success: true, charged_cents: nil) }) do
      collective.unarchive!(actor: owner)
    end

    assert_not collective.archived?
    assert_equal 0, sync_calls, "unarchive! on a non-archived collective should not touch Stripe"
  end

  test "archive! raises NotOwner when actor is not the collective creator" do
    tenant = create_tenant
    owner = create_user
    intruder = create_user
    collective = Collective.create!(tenant: tenant, created_by: owner, name: "Owner Guard", handle: "owner-guard-#{SecureRandom.hex(4)}")

    assert_raises(Collective::NotOwner) { collective.archive!(actor: intruder) }
    assert_not collective.reload.archived?, "archive! must not flip archived_at when actor check fails"
    assert_nil collective.archived_by_id
  end

  test "unarchive! clears archived_at and archived_by_id" do
    tenant = create_tenant
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Unarchive Test", handle: "unarchive-test-#{SecureRandom.hex(4)}")

    collective.archive!(actor: user)
    assert collective.archived?
    assert_not_nil collective.archived_by_id

    collective.unarchive!(actor: user)
    assert_not collective.archived?
    assert_nil collective.archived_at
    assert_nil collective.archived_by_id,
               "unarchive! must clear archived_by_id (archived_by_id IS NOT NULL iff archived_at IS NOT NULL)"
  end

  test "unarchive! raises NotOwner when actor is not the collective creator" do
    tenant = create_tenant
    owner = create_user
    intruder = create_user
    collective = Collective.create!(tenant: tenant, created_by: owner, name: "Unarch Guard", handle: "unarch-guard-#{SecureRandom.hex(4)}")
    collective.archive!(actor: owner)

    assert_raises(Collective::NotOwner) { collective.unarchive!(actor: intruder) }
    assert collective.reload.archived?, "unarchive! must not clear archived_at when actor check fails"
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
      enabled: true
    )

    collective.archive!(actor: user)

    rule.reload
    assert_not rule.enabled?, "Automation rule should be disabled after collective is archived"

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "archive! syncs Stripe subscription quantity for the owner on stripe_billing tenants" do
    tenant = create_tenant
    tenant.enable_feature_flag!("stripe_billing")
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Sync Test", handle: "sync-test-#{SecureRandom.hex(4)}")
    upgrade_collective_to_paid!(collective)

    synced_with = nil
    StripeService.stub(:sync_subscription_quantity!, ->(arg) { synced_with = arg; StripeService::SyncResult.new(success: true, charged_cents: nil) }) do
      collective.archive!(actor: user)
    end

    assert_equal user.id, synced_with&.id,
                 "archive! must sync Stripe subscription quantity for the collective's billable owner"
  end

  test "archive! does not sync Stripe when stripe_billing is not enabled on the tenant" do
    tenant = create_tenant
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(tenant: tenant, created_by: user, name: "No Sync", handle: "no-sync-#{SecureRandom.hex(4)}")

    sync_calls = 0
    StripeService.stub(:sync_subscription_quantity!, ->(_) { sync_calls += 1; StripeService::SyncResult.new(success: true, charged_cents: nil) }) do
      collective.archive!(actor: user)
    end

    assert_equal 0, sync_calls,
                 "archive! must not call Stripe sync on tenants without stripe_billing"
  end

  test "archive! downgrades a paid collective to free so unarchive doesn't silently resume billing" do
    tenant = create_tenant
    tenant.enable_feature_flag!("stripe_billing")
    tenant.enable_feature_flag!("trio")
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Auto Downgrade", handle: "auto-down-#{SecureRandom.hex(4)}")
    upgrade_collective_to_paid!(collective)
    collective.set_feature_flag!("trio", true)
    collective.set_feature_flag!("file_attachments", true)
    rule = AutomationRule.create!(
      tenant: tenant, collective: collective, created_by: user,
      name: "Rule", trigger_type: "manual", trigger_config: { "inputs" => {} },
      conditions: [], actions: {}, enabled: true,
    )

    StripeService.stub(:sync_subscription_quantity!, ->(_) { StripeService::SyncResult.new(success: true, charged_cents: nil) }) do
      collective.archive!(actor: user)
    end

    collective.reload
    assert_equal Collective::TIER_FREE, collective.tier,
                 "archive! must drop the collective back to the free tier"
    assert_not collective.feature_flag_enabled_locally?("trio"),
               "archive! must clear paid feature flags via downgrade cleanup"
    assert_not collective.feature_flag_enabled_locally?("file_attachments"),
               "archive! must clear paid feature flags via downgrade cleanup"
    assert_not rule.reload.enabled?,
               "archive! must disable automation rules (via downgrade cleanup)"
  end

  test "archive! on a free collective is a no-op for tier (no spurious tier change)" do
    tenant = create_tenant
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Free Archive", handle: "free-arch-#{SecureRandom.hex(4)}")
    assert_equal Collective::TIER_FREE, collective.tier

    collective.archive!(actor: user)

    assert collective.reload.archived?
    assert_equal Collective::TIER_FREE, collective.tier
  end

  test "unarchive! syncs Stripe subscription quantity for the owner on stripe_billing tenants" do
    tenant = create_tenant
    tenant.enable_feature_flag!("stripe_billing")
    user = create_user
    tenant.add_user!(user)
    collective = Collective.create!(tenant: tenant, created_by: user, name: "Unarchive Sync", handle: "unsync-#{SecureRandom.hex(4)}")
    upgrade_collective_to_paid!(collective)
    collective.archive!(actor: user)

    synced_with = nil
    StripeService.stub(:sync_subscription_quantity!, ->(arg) { synced_with = arg; StripeService::SyncResult.new(success: true, charged_cents: nil) }) do
      collective.unarchive!(actor: user)
    end

    assert_equal user.id, synced_with&.id,
                 "unarchive! must sync Stripe subscription quantity for the collective's billable owner"
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
      enabled: true
    )

    collective.archive!(actor: user)
    collective.unarchive!(actor: user)

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
      handle: "standard-#{SecureRandom.hex(4)}"
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
      handle: "identity-test-#{SecureRandom.hex(4)}"
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

  test "private workspace is not billing_exempt by default (bills like a collective)" do
    tenant = create_tenant(subdomain: "pw-billing-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    workspace = user.private_workspace
    assert_not workspace.billing_exempt?,
               "workspaces now use the free/paid tier model — billable when paid features are enabled"
  end

  test "collective_type must be a valid type" do
    tenant = create_tenant(subdomain: "ct-valid-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)

    assert_raises(ActiveRecord::RecordInvalid, /collective_type/) do
      Collective.create!(
        tenant: tenant,
        created_by: user,
        name: "Bad Type",
        handle: "bad-#{SecureRandom.hex(4)}",
        collective_type: "nonsense"
      )
    end
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

  test "listable scope returns only standard collectives" do
    tenant = create_tenant(subdomain: "pw-scope-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)
    Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Visible Collective",
      handle: "visible-#{SecureRandom.hex(4)}"
    )

    all = Collective.where(tenant_id: tenant.id)
    filtered = Collective.where(tenant_id: tenant.id).listable

    # All includes the workspace + the standard collective + main (if any)
    assert all.count > filtered.count, "Unfiltered should include more collectives than filtered"
    assert_equal 0, filtered.where(collective_type: "private_workspace").count
    filtered.each { |c| assert_equal "standard", c.collective_type }
  end

  test "listable? returns true for standard collectives and false for others" do
    tenant = create_tenant(subdomain: "listable-pred-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)

    standard = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Standard",
      handle: "std-#{SecureRandom.hex(4)}",
      collective_type: "standard"
    )
    assert standard.listable?

    workspace = user.private_workspace
    assert_not workspace.listable?
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

  # =========================================================================
  # Chat Collective tests
  # =========================================================================

  test "chat? returns true for chat collective_type" do
    tenant = create_tenant(subdomain: "chat-type-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)

    chat_collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Chat",
      handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat",
      billing_exempt: true
    )
    assert chat_collective.chat?
    assert_not chat_collective.listable?
    assert_not chat_collective.private_workspace?
  end

  test "chat collective does not create identity user" do
    tenant = create_tenant(subdomain: "chat-id-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)

    chat_collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Chat",
      handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat",
      billing_exempt: true
    )
    assert_nil chat_collective.identity_user
  end

  test "chat collective is excluded from listable scope" do
    tenant = create_tenant(subdomain: "chat-scope-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)

    Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Chat",
      handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat",
      billing_exempt: true
    )

    all = Collective.where(tenant_id: tenant.id)
    listable = Collective.where(tenant_id: tenant.id).listable
    assert listable.count < all.count, "Listable should exclude chat collectives"
    listable.each { |c| assert_equal "standard", c.collective_type }
  end

  test "find_or_create_shareable_invite raises for main collective" do
    tenant = create_tenant(subdomain: "main-invite-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    tenant.create_main_collective!(created_by: user)

    assert_raises(RuntimeError, "Cannot create invites for the main collective") do
      tenant.main_collective.find_or_create_shareable_invite(user)
    end
  end

  test "find_or_create_shareable_invite raises for chat collectives" do
    tenant = create_tenant(subdomain: "chat-invite-#{SecureRandom.hex(4)}")
    user = create_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user)

    chat_collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Chat",
      handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat",
      billing_exempt: true
    )
    assert_raises(RuntimeError) do
      chat_collective.find_or_create_shareable_invite(user)
    end
  end

  test "chat collective limits membership to two users" do
    tenant = create_tenant(subdomain: "chat-limit-#{SecureRandom.hex(4)}")
    user_a = create_user(name: "Alice")
    user_b = create_user(name: "Bob")
    user_c = create_user(name: "Carol")
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    tenant.add_user!(user_a)
    tenant.add_user!(user_b)
    tenant.add_user!(user_c)

    chat_collective = Collective.create!(
      tenant: tenant,
      created_by: user_a,
      name: "Chat",
      handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat",
      billing_exempt: true
    )

    previous_id = Collective.current_id
    previous_handle = Collective.current_handle
    begin
      Collective.set_thread_context(chat_collective)
      chat_collective.add_user!(user_a)
      chat_collective.add_user!(user_b)
      assert_raises(RuntimeError) do
        chat_collective.add_user!(user_c)
      end
    ensure
      Current.collective_id = previous_id
      Current.collective_handle = previous_handle
    end
  end

  # === Avatar Color Tests ===

  test "collective avatar_color is the collective color" do
    tenant = create_tenant(subdomain: "avcol-#{SecureRandom.hex(4)}")
    user = create_user
    collective = Collective.create!(tenant: tenant, created_by: user, name: "AvColor", handle: "avcol-#{SecureRandom.hex(4)}")
    assert_equal HasImage::COLLECTIVE_AVATAR_COLOR, collective.avatar_color
  end

  # === Tier state machine: constants & defaults ===

  test "TIER constants are defined" do
    assert_equal "free", Collective::TIER_FREE
    assert_equal "paid", Collective::TIER_PAID
    assert_equal "lapsed", Collective::TIER_LAPSED
    assert_equal %w[free paid lapsed], Collective::TIERS
  end

  test "VALID_TIER_TRANSITIONS map allows the documented moves" do
    assert_equal [Collective::TIER_PAID], Collective::VALID_TIER_TRANSITIONS[Collective::TIER_FREE]
    assert_includes Collective::VALID_TIER_TRANSITIONS[Collective::TIER_PAID], Collective::TIER_FREE
    assert_includes Collective::VALID_TIER_TRANSITIONS[Collective::TIER_PAID], Collective::TIER_LAPSED
    assert_includes Collective::VALID_TIER_TRANSITIONS[Collective::TIER_LAPSED], Collective::TIER_PAID
    assert_includes Collective::VALID_TIER_TRANSITIONS[Collective::TIER_LAPSED], Collective::TIER_FREE
  end

  test "new collective defaults to free tier" do
    c = build_collective
    assert_equal Collective::TIER_FREE, c.tier
  end

  test "tier rejects values outside TIERS" do
    c = build_collective
    c.tier = "garbage"
    assert_not c.valid?
    assert c.errors[:tier].any?
  end

  test "tier rejects invalid transition (free -> lapsed)" do
    c = build_collective
    c.tier = Collective::TIER_LAPSED
    assert_not c.valid?
    assert c.errors[:tier].any?
  end

  test "tier accepts valid transition free -> paid" do
    c = build_collective
    c.tier = Collective::TIER_PAID
    assert c.valid?
  end

  # === Predicates (column-driven) ===

  test "paid_tier? returns true iff tier column is paid" do
    c = build_collective
    assert_not c.paid_tier?
    c.update!(tier: Collective::TIER_PAID)
    assert c.paid_tier?
    c.update!(tier: Collective::TIER_LAPSED)
    assert_not c.paid_tier?
  end

  test "free_tier? is the inverse of paid_tier?" do
    c = build_collective
    assert c.free_tier?
    c.update!(tier: Collective::TIER_PAID)
    assert_not c.free_tier?
  end

  test "requires_stripe_billing? returns true only when tier is lapsed" do
    c = build_collective
    assert_not c.requires_stripe_billing?
    c.update!(tier: Collective::TIER_PAID)
    assert_not c.requires_stripe_billing?
    c.update!(tier: Collective::TIER_LAPSED)
    assert c.requires_stripe_billing?
  end

  test "main collective stays free but trio_enabled? short-circuits" do
    tenant = create_tenant(subdomain: "main-tier-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.create_main_collective!(created_by: user)
    main = tenant.main_collective
    assert_equal Collective::TIER_FREE, main.tier
    assert_not main.paid_tier?
    tenant.enable_feature_flag!("trio")
    main.enable_feature_flag!("trio")
    assert main.trio_enabled?, "main collective trio_enabled? should short-circuit on is_main_collective?"
  end

  test "free non-main collective has trio_enabled? gated off even with flag set" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    c.tenant.enable_feature_flag!("trio")
    c.enable_feature_flag!("trio")
    assert_not c.trio_enabled?
  end

  test "non-billing tenant: free collective still has trio_enabled? when flag is set (self-hosted)" do
    c = build_collective
    # No stripe_billing flag — tier model is not in effect, features should
    # work freely (self-hosted instance behavior).
    c.tenant.enable_feature_flag!("trio")
    c.enable_feature_flag!("trio")
    assert c.trio_enabled?, "non-billing tenant should bypass the tier gate"
  end

  test "paid collective has trio_enabled? when flag is set" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    c.tenant.enable_feature_flag!("trio")
    c.enable_feature_flag!("trio")
    c.update!(tier: Collective::TIER_PAID)
    assert c.trio_enabled?
  end

  test "lapsed collective has trio_enabled? gated off (paused)" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    c.tenant.enable_feature_flag!("trio")
    c.enable_feature_flag!("trio")
    c.update!(tier: Collective::TIER_PAID)
    c.update!(tier: Collective::TIER_LAPSED)
    assert_not c.trio_enabled?
  end

  test "free non-main collective has file_attachments_enabled? gated off" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    c.enable_feature_flag!("file_attachments")
    assert_not c.file_attachments_enabled?
  end

  test "non-billing tenant: free collective still has file_attachments_enabled? (self-hosted)" do
    c = build_collective
    c.enable_feature_flag!("file_attachments")
    assert c.file_attachments_enabled?, "non-billing tenant should bypass the tier gate"
  end

  test "paid collective has file_attachments_enabled? when flag is set" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    c.enable_feature_flag!("file_attachments")
    c.update!(tier: Collective::TIER_PAID)
    assert c.file_attachments_enabled?
  end

  # === Transition methods ===

  test "upgrade! flips free->paid when actor has active stripe customer" do
    c = build_collective
    owner = c.created_by
    StripeCustomer.create!(billable: owner, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    c.upgrade!(actor: owner)
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "upgrade! raises BillingRequired when actor lacks active stripe customer" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    assert_raises(Collective::BillingRequired) do
      c.upgrade!(actor: c.created_by)
    end
    assert_equal Collective::TIER_FREE, c.reload.tier
  end

  test "upgrade! does not require billing when tenant has stripe_billing disabled" do
    c = build_collective
    c.upgrade!(actor: c.created_by)
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "upgrade! does not require billing when collective is billing_exempt" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    c.update!(billing_exempt: true)
    c.upgrade!(actor: c.created_by)
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "upgrade! does not require billing when actor is a sys/app admin" do
    c = build_collective
    enable_stripe_billing!(c.tenant)
    c.created_by.update!(sys_admin: true)
    c.upgrade!(actor: c.created_by)
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "upgrade! raises NotOwner when actor is not the creator" do
    c = build_collective
    other = create_user
    StripeCustomer.create!(billable: other, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    assert_raises(Collective::NotOwner) do
      c.upgrade!(actor: other)
    end
  end

  test "upgrade! is idempotent when already paid" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.upgrade!(actor: c.created_by)
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "confirm_upgrade! flips free->paid (webhook entry point)" do
    c = build_collective
    c.confirm_upgrade!
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "confirm_upgrade! is idempotent when already paid" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.confirm_upgrade!
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "downgrade! flips paid->free and disables automations + paid flags" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.tenant.enable_feature_flag!("trio")
    c.enable_feature_flag!("trio")
    c.enable_feature_flag!("file_attachments")
    rule = create_automation_rule(c, enabled: true)
    c.downgrade!(actor: c.created_by)
    assert_equal Collective::TIER_FREE, c.reload.tier
    assert_not rule.reload.enabled, "downgrade! must disable enabled automations"
    assert_not c.feature_flag_enabled_locally?("trio"), "downgrade! must clear local trio flag"
    assert_not c.feature_flag_enabled_locally?("file_attachments"), "downgrade! must clear local file_attachments flag"
  end

  test "downgrade! raises NotOwner when actor is not the creator" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    other = create_user
    assert_raises(Collective::NotOwner) do
      c.downgrade!(actor: other)
    end
  end

  test "downgrade! works from lapsed->free" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.update!(tier: Collective::TIER_LAPSED)
    c.downgrade!(actor: c.created_by)
    assert_equal Collective::TIER_FREE, c.reload.tier
  end

  test "downgrade! is idempotent when already free" do
    c = build_collective
    c.downgrade!(actor: c.created_by)
    assert_equal Collective::TIER_FREE, c.reload.tier
  end

  test "upgrade! and downgrade! are no-ops on main collectives (defense in depth)" do
    tenant = create_tenant(subdomain: "main-up-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.create_main_collective!(created_by: user)
    main = tenant.main_collective
    StripeCustomer.create!(billable: user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    # Even though the upgrade/downgrade routes exist for any handle, main
    # collectives are always feature-unlocked via the is_main_collective?
    # short-circuit and never billed.
    main.upgrade!(actor: user)
    assert_equal Collective::TIER_FREE, main.reload.tier
    main.update!(tier: Collective::TIER_PAID) # bypass the no-op for the downgrade leg
    main.downgrade!(actor: user)
    assert_equal Collective::TIER_PAID, main.reload.tier, "downgrade! should not touch a main collective"
  end

  test "mark_lapsed! flips paid->lapsed without disabling features" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.tenant.enable_feature_flag!("trio")
    c.enable_feature_flag!("trio")
    rule = create_automation_rule(c, enabled: true)
    c.mark_lapsed!
    assert_equal Collective::TIER_LAPSED, c.reload.tier
    assert rule.reload.enabled, "mark_lapsed! must NOT disable existing rules"
    assert c.feature_flag_enabled_locally?("trio"), "mark_lapsed! must preserve trio flag"
  end

  test "mark_lapsed! is idempotent when already lapsed" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.update!(tier: Collective::TIER_LAPSED)
    c.mark_lapsed!
    assert_equal Collective::TIER_LAPSED, c.reload.tier
  end

  test "restore_from_lapsed! flips lapsed->paid" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.update!(tier: Collective::TIER_LAPSED)
    c.restore_from_lapsed!
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  test "restore_from_lapsed! is a no-op for free collectives" do
    c = build_collective
    c.restore_from_lapsed!
    assert_equal Collective::TIER_FREE, c.reload.tier
  end

  test "restore_from_lapsed! is idempotent when already paid" do
    c = build_collective
    c.update!(tier: Collective::TIER_PAID)
    c.restore_from_lapsed!
    assert_equal Collective::TIER_PAID, c.reload.tier
  end

  # === billable_types scope ===

  test "billable_types scope includes standard and private_workspace" do
    tenant = create_tenant(subdomain: "bt-#{SecureRandom.hex(4)}")
    user = create_user
    standard = Collective.create!(tenant: tenant, created_by: user, name: "S", handle: "s-#{SecureRandom.hex(4)}")
    pw = Collective.create!(tenant: tenant, created_by: user, name: "P", handle: "p-#{SecureRandom.hex(4)}", collective_type: "private_workspace")
    chat = Collective.create!(tenant: tenant, created_by: user, name: "C", handle: "c-#{SecureRandom.hex(4)}", collective_type: "chat")

    ids = Collective.billable_types.where(tenant_id: tenant.id).pluck(:id)
    assert_includes ids, standard.id
    assert_includes ids, pw.id
    assert_not_includes ids, chat.id
  end

  private

  def build_collective(subdomain_prefix: "bc")
    tenant = create_tenant(subdomain: "#{subdomain_prefix}-#{SecureRandom.hex(4)}")
    user = create_user
    Collective.create!(
      tenant: tenant, created_by: user,
      name: "Build Collective", handle: "bc-#{SecureRandom.hex(4)}"
    )
  end

  def enable_stripe_billing!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  def create_automation_rule(collective, enabled: true)
    AutomationRule.create!(
      tenant: collective.tenant,
      collective: collective,
      created_by: collective.created_by,
      name: "Rule #{SecureRandom.hex(4)}",
      trigger_type: "manual",
      trigger_config: { "inputs" => {} },
      conditions: [],
      actions: {},
      enabled: enabled
    )
  end
end
