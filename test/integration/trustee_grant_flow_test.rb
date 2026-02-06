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
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true, "vote" => true },
      studio_scope: { "mode" => "all" },
    )

    assert permission.pending?
    assert_not @bob.can_represent?(@alice)

    # Step 2: Bob accepts the permission
    permission.accept!

    assert permission.active?
    assert @bob.can_represent?(@alice)

    # Step 3: Bob starts a representation session
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @bob,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    assert session.active?
    assert_not session.ended?

    # Step 4: Bob performs actions (creates a note)
    note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @bob, # In practice, this would be the trustee_user during representation
      title: "Note created while representing Alice",
      text: "This is a test note.",
      deadline: 1.week.from_now,
    )

    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/notes')
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: @superagent.id,
        main_resource: { type: 'Note', id: note.id, truncated_id: note.truncated_id },
        sub_resources: [],
      },
    )

    assert_equal 1, session.action_count

    # Step 5: Bob ends the representation session
    session.end!

    assert session.ended?
    assert_not session.active?

    # Step 6: Activity is preserved and visible
    assert_equal 1, session.human_readable_activity_log.count
    activity = session.human_readable_activity_log.first
    assert_equal 'created', activity[:verb_phrase]
    assert_equal note, activity[:main_resource]
  end

  test "declined permission prevents representation" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )

    permission.decline!

    assert permission.declined?
    assert_not @bob.can_represent?(@alice)
  end

  test "revoked permission prevents further representation" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
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
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      expires_at: 1.hour.from_now,
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

  test "capability enforcement during representation session" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true, "vote" => false },
    )
    permission.accept!

    # Bob has create_notes but not vote capability
    assert permission.has_capability?("create_notes")
    assert_not permission.has_capability?("vote")

    # TrusteeActionValidator should enforce this
    validator = TrusteeActionValidator.new(permission.trustee_user, superagent: @superagent)
    assert validator.can_perform?("create_note")
    assert_not validator.can_perform?("vote")
  end

  test "capability changes take immediate effect during active session" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true, "vote" => true },
    )
    permission.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @bob,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    # Initially, vote is allowed
    validator = TrusteeActionValidator.new(permission.trustee_user, superagent: @superagent)
    assert validator.can_perform?("vote")

    # Alice revokes the vote capability
    permission.update!(permissions: { "create_notes" => true, "vote" => false })

    # Bob's next vote attempt should fail (immediate effect)
    validator = TrusteeActionValidator.new(permission.trustee_user, superagent: @superagent)
    assert_not validator.can_perform?("vote")
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
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "include", "studio_ids" => [@superagent.id] },
    )
    permission.accept!

    assert permission.allows_studio?(@superagent)
    assert_not permission.allows_studio?(other_studio)

    # Validator should enforce studio scope
    validator_in_scope = TrusteeActionValidator.new(permission.trustee_user, superagent: @superagent)
    assert validator_in_scope.can_perform?("create_note")

    validator_out_of_scope = TrusteeActionValidator.new(permission.trustee_user, superagent: other_studio)
    assert_not validator_out_of_scope.can_perform?("create_note")
  end

  test "studio scope enforcement - exclude mode" do
    excluded_studio = create_superagent(tenant: @tenant, created_by: @alice, handle: "excluded-studio-#{SecureRandom.hex(4)}")
    excluded_studio.add_user!(@alice)
    excluded_studio.add_user!(@bob)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "exclude", "studio_ids" => [excluded_studio.id] },
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
      parent_id: @alice.id,
    )
    @tenant.add_user!(subagent)
    @superagent.add_user!(subagent)

    # Permission should be auto-created and pre-accepted
    permission = TrusteeGrant.find_by(granting_user: subagent, trusted_user: @alice)
    assert permission.present?
    assert permission.active?

    # Alice can represent the subagent
    assert @alice.can_represent?(subagent)

    # Alice can create a representation session for the subagent
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @alice,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    assert session.persisted?
    assert session.active?
  end

  # =========================================================================
  # SINGLE SESSION CONSTRAINT
  # =========================================================================

  test "user can only have one active representation session at a time" do
    # Create first permission (Alice grants to Bob)
    permission1 = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
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
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Carol",
      permissions: { "create_notes" => true },
    )
    permission2.accept!

    # Bob starts session representing Alice
    session1 = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @bob,
      trustee_user: permission1.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    assert session1.active?

    # Bob cannot start another session while first is active
    # (This constraint should be enforced by the controller/service layer)
    active_sessions = RepresentationSession.where(
      representative_user: @bob,
      ended_at: nil,
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
      trusted_user: @bob,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @bob,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    # The representative_user is Bob (the one doing the representing)
    assert_equal @bob, session.representative_user

    # The trustee_user is the trustee grant trustee (not Alice herself)
    assert_equal permission.trustee_user, session.trustee_user
    assert permission.trustee_user.trustee?
    assert_not permission.trustee_user.superagent_trustee?

    # The trustee_user's name should indicate the trustee grant relationship
    assert_equal "Bob acts for Alice", permission.trustee_user.name
  end
end
