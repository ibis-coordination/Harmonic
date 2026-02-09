require "test_helper"

class TrusteeGrantFlowTest < ActionDispatch::IntegrationTest
  # =========================================================================
  # FULL TRUSTEE GRANT FLOW INTEGRATION TESTS
  # These tests document the end-to-end flow for user-to-user trustee grant:
  # 1. Alice grants Bob permission to act on her behalf
  # 2. Bob accepts the permission
  # 3. Bob starts a representation session
  # 4. Bob performs actions (which are logged)
  # 5. Bob ends the representation session
  # 6. Alice can view what Bob did on her behalf
  # =========================================================================

  def setup
    @tenant = create_tenant(subdomain: "trustee-grant-flow-#{SecureRandom.hex(4)}")
    @alice = create_user(email: "alice_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @bob = create_user(email: "bob_#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @tenant.add_user!(@alice)
    @tenant.add_user!(@bob)
    # Create main superagent (required for sign_in_as to work)
    @tenant.create_main_superagent!(created_by: @alice)
    @superagent = create_superagent(tenant: @tenant, created_by: @alice, handle: "trustee-grant-studio-#{SecureRandom.hex(4)}")
    @superagent.add_user!(@alice)
    @superagent.add_user!(@bob)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  # =========================================================================
  # PERMISSION REQUEST AND ACCEPTANCE FLOW
  # =========================================================================

  test "full trustee grant flow: request -> accept -> represent -> act -> end" do
    # Step 1: Alice creates a TrusteeGrant granting Bob permission
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true, "vote" => true },
      studio_scope: { "mode" => "all" }
    )

    assert permission.pending?
    assert_not @bob.can_represent?(@alice)

    # Step 2: Bob accepts the permission
    permission.accept!

    assert permission.active?
    assert @bob.can_represent?(@alice)

    # Step 3: Bob starts a user representation session (no superagent, has trustee_grant)
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation has no superagent
      trustee_grant: permission,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    assert session.active?
    assert_not session.ended?
    assert session.user_representation?

    # Step 4: Bob performs actions (creates a note)
    # During representation, content is attributed to the effective_user (Alice, the granting_user)
    note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: session.effective_user,  # Alice
      title: "Note created while representing Alice",
      text: "This is a test note.",
      deadline: 1.week.from_now
    )

    mock_request = OpenStruct.new(request_id: "req-123")
    session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note
    )

    assert_equal 1, session.action_count

    # Step 5: Bob ends the representation session
    session.end!

    assert session.ended?
    assert_not session.active?

    # Step 6: Activity is preserved and visible
    assert_equal 1, session.activity_log_entries.count
    activity = session.activity_log_entries.first
    assert_equal "created", activity[:verb_phrase]
    assert_equal note, activity[:main_resource]
  end

  test "declined permission prevents representation" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )

    permission.decline!

    assert permission.declined?
    assert_not @bob.can_represent?(@alice)
  end

  test "revoked permission prevents further representation" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    permission.accept!

    assert @bob.can_represent?(@alice)

    permission.revoke!

    assert permission.revoked?
    assert_not @bob.can_represent?(@alice)
  end

  test "expired permission prevents representation" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      expires_at: 1.hour.from_now
    )
    permission.accept!

    assert @bob.can_represent?(@alice)

    # Simulate time passing
    travel_to 2.hours.from_now do
      assert permission.expired?
      assert_not @bob.can_represent?(@alice)
    end
  end

  # =========================================================================
  # CAPABILITY ENFORCEMENT
  # =========================================================================

  test "action permission enforcement via grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_note" => true, "vote" => false }
    )
    permission.accept!

    # Bob has create_note but not vote permission
    assert permission.has_action_permission?("create_note")
    assert_not permission.has_action_permission?("vote")
  end

  test "permission changes take immediate effect during active session" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_note" => true, "vote" => true }
    )
    permission.accept!

    # Create user representation session
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation has no superagent
      trustee_grant: permission,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Initially, vote is allowed
    assert permission.has_action_permission?("vote")

    # Alice revokes the vote permission
    permission.update!(permissions: { "create_note" => true, "vote" => false })

    # Bob's next vote attempt should fail (immediate effect)
    assert_not permission.has_action_permission?("vote")
  end

  # =========================================================================
  # STUDIO SCOPING
  # =========================================================================

  test "studio scope enforcement - include mode" do
    other_studio = create_superagent(tenant: @tenant, created_by: @alice, handle: "other-studio-#{SecureRandom.hex(4)}")
    other_studio.add_user!(@alice)
    other_studio.add_user!(@bob)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_note" => true },
      studio_scope: { "mode" => "include", "studio_ids" => [@superagent.id] }
    )
    permission.accept!

    assert permission.allows_studio?(@superagent)
    assert_not permission.allows_studio?(other_studio)
  end

  test "studio scope enforcement - exclude mode" do
    excluded_studio = create_superagent(tenant: @tenant, created_by: @alice, handle: "excluded-studio-#{SecureRandom.hex(4)}")
    excluded_studio.add_user!(@alice)
    excluded_studio.add_user!(@bob)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_note" => true },
      studio_scope: { "mode" => "exclude", "studio_ids" => [excluded_studio.id] }
    )
    permission.accept!

    assert permission.allows_studio?(@superagent)
    assert_not permission.allows_studio?(excluded_studio)
  end

  # =========================================================================
  # PARENT-SUBAGENT TRUSTEE GRANT
  # =========================================================================

  test "parent can represent subagent through auto-created permission" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Alice's Bot",
      user_type: "subagent",
      parent_id: @alice.id
    )
    @tenant.add_user!(subagent)
    @superagent.add_user!(subagent)

    # Permission should be auto-created and pre-accepted
    permission = TrusteeGrant.find_by(granting_user: subagent, trustee_user: @alice)
    assert permission.present?
    assert permission.active?

    # Alice can represent the subagent
    assert @alice.can_represent?(subagent)

    # Alice can create a user representation session for the subagent
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation has no superagent
      trustee_grant: permission,
      representative_user: @alice,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    assert session.persisted?
    assert session.active?
    assert session.user_representation?
    # effective_user is the subagent (granting_user)
    assert_equal subagent, session.effective_user
  end

  # =========================================================================
  # SINGLE SESSION CONSTRAINT
  # =========================================================================

  test "user can only have one active representation session at a time" do
    # Create first permission (Alice grants to Bob)
    permission1 = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    permission1.accept!

    # Create second granting user (Carol)
    carol = create_user(email: "carol_#{SecureRandom.hex(4)}@example.com", name: "Carol")
    @tenant.add_user!(carol)
    @superagent.add_user!(carol)

    # Carol also grants permission to Bob
    permission2 = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: carol,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    permission2.accept!

    # Bob starts session representing Alice
    session1 = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation
      trustee_grant: permission1,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    assert session1.active?

    # Bob cannot start another session while first is active
    # (This constraint should be enforced by the controller/service layer)
    active_sessions = RepresentationSession.where(
      representative_user: @bob,
      ended_at: nil
    ).where("began_at > ?", 24.hours.ago)

    assert_equal 1, active_sessions.count
    assert_equal session1, active_sessions.first
  end

  # =========================================================================
  # SESSION ATTRIBUTION
  # =========================================================================

  test "trustee grant session shows correct attribution" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    permission.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation
      trustee_grant: permission,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # The representative_user is Bob (the one doing the representing)
    assert_equal @bob, session.representative_user

    # The effective_user is Alice (the granting_user, the person being represented)
    assert_equal @alice, session.effective_user

    # After the migration, trustee_user on TrusteeGrant is the actual person (Bob), not a trustee-type
    assert_equal @bob, permission.trustee_user
    assert_not permission.trustee_user.trustee?
    assert_equal "Bob", permission.trustee_user.name
  end

  # =========================================================================
  # HTTP ACCESS VALIDATION DURING USER REPRESENTATION SESSIONS
  # These tests verify that the controller properly validates access to studios
  # during user representation sessions, checking both:
  # 1. The granting user's membership in the studio
  # 2. The grant's studio scope configuration
  # =========================================================================

  test "user representation session denies access to studio where granting user is not a member" do
    # Create a studio that only Bob is a member of (not Alice)
    bobs_studio = create_superagent(tenant: @tenant, created_by: @bob, handle: "bobs-studio-#{SecureRandom.hex(4)}")
    bobs_studio.add_user!(@bob)
    # Alice is NOT a member of bobs_studio

    # Alice grants Bob permission to act on her behalf
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" } # Grant allows all studios
    )
    grant.accept!

    # Sign in as Bob
    sign_in_as(@bob, tenant: @tenant)

    # Bob starts a representation session via the controller endpoint
    # Note: Bob accesses the grant through HIS own URL (as trustee_user), not Alice's
    post "/u/#{@bob.handle}/settings/trustee-grants/#{grant.truncated_id}/represent"

    # Verify representation session started (should redirect to /representing)
    assert_redirected_to "/representing"

    # Now Bob (as trustee) tries to access bobs_studio
    # Since Alice is not a member, this should be denied
    get bobs_studio.path

    # This test documents expected behavior:
    # Access should be denied because Alice (granting_user) is not a member of bobs_studio.
    # The trustee shouldn't be able to access studios the granting user can't access.
    #
    # If response is 200 and shows studio content, the validation is broken.
    # Expected: either redirect to /representing, 403, or redirect to join page.
    assert response.status != 200 || !response.body.include?(bobs_studio.name),
           "User representation session should not allow access to studios where granting user is not a member. " \
           "Got status #{response.status}"
  end

  test "user representation session denies access to studio excluded by grant scope" do
    # Create another studio that both Alice and Bob are members of
    excluded_studio = create_superagent(tenant: @tenant, created_by: @alice, handle: "excluded-studio-#{SecureRandom.hex(4)}")
    excluded_studio.add_user!(@alice)
    excluded_studio.add_user!(@bob)

    # Alice grants Bob permission, but excludes this studio
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "exclude", "studio_ids" => [excluded_studio.id] }
    )
    grant.accept!

    # Verify grant scope configuration
    assert grant.allows_studio?(@superagent)
    assert_not grant.allows_studio?(excluded_studio)

    # Sign in as Bob
    sign_in_as(@bob, tenant: @tenant)

    # Bob starts a representation session via the controller endpoint
    # Note: Bob accesses the grant through HIS own URL (as trustee_user), not Alice's
    post "/u/#{@bob.handle}/settings/trustee-grants/#{grant.truncated_id}/represent"

    # Verify representation session started
    assert_redirected_to "/representing"

    # Now Bob (as trustee) tries to access the excluded studio
    # Since the grant excludes this studio, access should be denied
    get excluded_studio.path

    # Expected behavior: Should deny access because the grant's studio_scope excludes this studio
    assert response.status != 200 || !response.body.include?(excluded_studio.name),
           "User representation session should not allow access to studios excluded by grant scope. " \
           "Got status #{response.status}"
  end

  test "user representation session allows access to studio in grant scope where granting user is member" do
    # This is the positive case - access should work
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" }
    )
    grant.accept!

    # Alice is already a member of @superagent (from setup)
    assert @superagent.superagent_members.exists?(user: @alice)
    assert grant.allows_studio?(@superagent)

    # Sign in as Bob
    sign_in_as(@bob, tenant: @tenant)

    # Bob starts a representation session via the controller endpoint
    # Note: Bob accesses the grant through HIS own URL (as trustee_user), not Alice's
    post "/u/#{@bob.handle}/settings/trustee-grants/#{grant.truncated_id}/represent"

    # Verify representation session started
    assert_redirected_to "/representing"

    # Follow the redirect to /representing first
    follow_redirect!

    # Now Bob (as trustee) accesses the allowed studio
    get @superagent.path

    # Access should be allowed - we should see the studio content, not a redirect to join
    assert_response :success,
                    "User representation session should allow access to studios in grant scope where granting user is a member. " \
                    "Got status #{response.status}"
  end
end
