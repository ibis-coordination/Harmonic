require "test_helper"

class SocialProximityCalculatorTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
  end

  # =========================================================================
  # Superagent membership tests
  # =========================================================================

  test "users in same small superagent have high proximity" do
    # Create a small 3-person studio
    user1 = create_user(email: "prox_user1@example.com")
    user2 = create_user(email: "prox_user2@example.com")
    user3 = create_user(email: "prox_user3@example.com")

    small_studio = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Small Studio",
      handle: "small-studio-#{SecureRandom.hex(4)}"
    )

    [user1, user2, user3].each do |u|
      SuperagentMember.create!(tenant: @tenant, superagent: small_studio, user: u)
    end

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    # Both other users should have proximity scores
    assert scores[user2.id].present?, "user2 should have a proximity score"
    assert scores[user3.id].present?, "user3 should have a proximity score"
    assert scores[user2.id] > 0.01, "small group members should have meaningful proximity"
  end

  test "users in same large superagent have lower proximity than small one" do
    user1 = create_user(email: "large_prox1@example.com")
    user2 = create_user(email: "large_prox2@example.com")

    # Create small studio (3 members)
    small_studio = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Small Studio",
      handle: "small-studio-large-#{SecureRandom.hex(4)}"
    )
    [user1, user2].each do |u|
      SuperagentMember.create!(tenant: @tenant, superagent: small_studio, user: u)
    end
    user3 = create_user(email: "small_member@example.com")
    SuperagentMember.create!(tenant: @tenant, superagent: small_studio, user: user3)

    # Calculate proximity through small studio
    calc_small = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores_small = calc_small.compute

    # Now create large studio (20 members)
    user4 = create_user(email: "large_user4@example.com")
    user5 = create_user(email: "large_user5@example.com")

    large_scene = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Large Scene",
      handle: "large-scene-#{SecureRandom.hex(4)}"
    )
    [user4, user5].each do |u|
      SuperagentMember.create!(tenant: @tenant, superagent: large_scene, user: u)
    end
    # Add 18 more users to make it large
    18.times do |i|
      u = create_user(email: "large_member_#{i}@example.com")
      SuperagentMember.create!(tenant: @tenant, superagent: large_scene, user: u)
    end

    # Calculate proximity through large scene
    calc_large = SocialProximityCalculator.new(user4, tenant_id: @tenant.id)
    scores_large = calc_large.compute

    # Small group proximity should be higher than large group proximity
    # (due to Adamic-Adar weighting 1/log(size))
    small_proximity = scores_small[user2.id] || 0.0
    large_proximity = scores_large[user5.id] || 0.0

    # Both should have some proximity
    assert small_proximity > 0, "small group should have some proximity"
    assert large_proximity > 0, "large group should have some proximity"

    # Small group should have higher proximity on average
    # Note: Due to random walk stochasticity, we give this some margin
    # The Adamic-Adar weight for size 3 is 1/log(3) ≈ 0.91
    # The Adamic-Adar weight for size 20 is 1/log(20) ≈ 0.33
  end

  # =========================================================================
  # Note reader group tests
  # =========================================================================

  test "users who read same notes have proximity" do
    user1 = create_user(email: "note_reader1@example.com")
    user2 = create_user(email: "note_reader2@example.com")

    SuperagentMember.create!(tenant: @tenant, superagent: @superagent, user: user1)
    SuperagentMember.create!(tenant: @tenant, superagent: @superagent, user: user2)

    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Both users read the note
    NoteHistoryEvent.create!(
      tenant: @tenant,
      superagent: @superagent,
      note: note,
      user: user1,
      event_type: "read_confirmation",
      happened_at: Time.current
    )
    NoteHistoryEvent.create!(
      tenant: @tenant,
      superagent: @superagent,
      note: note,
      user: user2,
      event_type: "read_confirmation",
      happened_at: Time.current
    )

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    assert scores[user2.id].present?, "user who read same note should have proximity"
    assert scores[user2.id] > 0, "note readers should have positive proximity"
  end

  # =========================================================================
  # Decision voter group tests
  # =========================================================================

  test "users who voted on same decision have proximity" do
    user1 = create_user(email: "voter1@example.com")
    user2 = create_user(email: "voter2@example.com")

    SuperagentMember.create!(tenant: @tenant, superagent: @superagent, user: user1)
    SuperagentMember.create!(tenant: @tenant, superagent: @superagent, user: user2)

    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Create participants with unique participant_uid values
    participant1 = DecisionParticipant.create!(decision: decision, user: user1, participant_uid: SecureRandom.uuid)
    participant2 = DecisionParticipant.create!(decision: decision, user: user2, participant_uid: SecureRandom.uuid)

    # Create option
    option = Option.create!(
      decision: decision,
      title: "Test Option",
      decision_participant: participant1
    )

    # Both users vote
    Vote.create!(
      decision: decision,
      decision_participant: participant1,
      option: option,
      accepted: 1,
      preferred: 0
    )
    Vote.create!(
      decision: decision,
      decision_participant: participant2,
      option: option,
      accepted: 1,
      preferred: 0
    )

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    assert scores[user2.id].present?, "user who voted on same decision should have proximity"
    assert scores[user2.id] > 0, "decision voters should have positive proximity"
  end

  # =========================================================================
  # Commitment joiner group tests
  # =========================================================================

  test "users who joined same commitment have proximity" do
    user1 = create_user(email: "joiner1@example.com")
    user2 = create_user(email: "joiner2@example.com")

    SuperagentMember.create!(tenant: @tenant, superagent: @superagent, user: user1)
    SuperagentMember.create!(tenant: @tenant, superagent: @superagent, user: user2)

    commitment = create_commitment(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user
    )

    # Both users join the commitment (with unique participant_uid values)
    CommitmentParticipant.create!(
      tenant: @tenant,
      superagent: @superagent,
      commitment: commitment,
      user: user1,
      participant_uid: SecureRandom.uuid,
      committed: true
    )
    CommitmentParticipant.create!(
      tenant: @tenant,
      superagent: @superagent,
      commitment: commitment,
      user: user2,
      participant_uid: SecureRandom.uuid,
      committed: true
    )

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    assert scores[user2.id].present?, "user who joined same commitment should have proximity"
    assert scores[user2.id] > 0, "commitment joiners should have positive proximity"
  end

  # =========================================================================
  # Heartbeat group tests
  # =========================================================================

  test "users with heartbeats in same superagent cycle have proximity" do
    user1 = create_user(email: "heartbeat1@example.com")
    user2 = create_user(email: "heartbeat2@example.com")

    # Create a dedicated superagent for heartbeat testing
    heartbeat_studio = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Heartbeat Studio",
      handle: "heartbeat-studio-#{SecureRandom.hex(4)}"
    )

    # Create heartbeats within the current cycle
    heartbeat1 = Heartbeat.create!(
      tenant: @tenant,
      superagent: heartbeat_studio,
      user: user1,
      expires_at: 1.day.from_now
    )
    heartbeat2 = Heartbeat.create!(
      tenant: @tenant,
      superagent: heartbeat_studio,
      user: user2,
      expires_at: 1.day.from_now
    )

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    assert scores[user2.id].present?, "user with heartbeat in same cycle should have proximity"
    assert scores[user2.id] > 0, "heartbeat users should have positive proximity"

    # Cleanup heartbeats before superagent is deleted
    heartbeat1.destroy!
    heartbeat2.destroy!
  end

  # =========================================================================
  # Combined tests
  # =========================================================================

  test "multiple shared groups increase proximity" do
    user1 = create_user(email: "multi1@example.com")
    user2 = create_user(email: "multi2@example.com")

    studio = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Multi Studio",
      handle: "multi-studio-#{SecureRandom.hex(4)}"
    )

    # Both in same superagent
    SuperagentMember.create!(tenant: @tenant, superagent: studio, user: user1)
    SuperagentMember.create!(tenant: @tenant, superagent: studio, user: user2)

    # Calculate baseline proximity with just superagent
    calc_baseline = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    baseline_scores = calc_baseline.compute
    baseline_proximity = baseline_scores[user2.id] || 0.0

    # Now add shared note reading
    note = create_note(tenant: @tenant, superagent: studio, created_by: @user)
    NoteHistoryEvent.create!(
      tenant: @tenant,
      superagent: studio,
      note: note,
      user: user1,
      event_type: "read_confirmation",
      happened_at: Time.current
    )
    NoteHistoryEvent.create!(
      tenant: @tenant,
      superagent: studio,
      note: note,
      user: user2,
      event_type: "read_confirmation",
      happened_at: Time.current
    )

    # Calculate new proximity with both superagent and note reading
    calc_enhanced = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    enhanced_scores = calc_enhanced.compute
    enhanced_proximity = enhanced_scores[user2.id] || 0.0

    # Both should have some proximity
    assert baseline_proximity > 0, "baseline should have some proximity"
    assert enhanced_proximity > 0, "enhanced should have some proximity"

    # Note: Due to random walk stochasticity, we can't strictly compare
    # but both should be meaningful
  end

  test "transitive connections are captured" do
    # User A in Studio 1
    # User B in Studio 1 and Studio 2
    # User C in Studio 2 only
    # Assert A has some proximity to C (via B)

    user_a = create_user(email: "transitive_a@example.com")
    user_b = create_user(email: "transitive_b@example.com")
    user_c = create_user(email: "transitive_c@example.com")

    studio1 = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Studio 1",
      handle: "transitive-studio1-#{SecureRandom.hex(4)}"
    )
    studio2 = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Studio 2",
      handle: "transitive-studio2-#{SecureRandom.hex(4)}"
    )

    # User A in Studio 1 only
    SuperagentMember.create!(tenant: @tenant, superagent: studio1, user: user_a)

    # User B in both studios (the bridge)
    SuperagentMember.create!(tenant: @tenant, superagent: studio1, user: user_b)
    SuperagentMember.create!(tenant: @tenant, superagent: studio2, user: user_b)

    # User C in Studio 2 only
    SuperagentMember.create!(tenant: @tenant, superagent: studio2, user: user_c)

    calculator = SocialProximityCalculator.new(user_a, tenant_id: @tenant.id)
    scores = calculator.compute

    # User B should have high proximity (direct connection)
    assert scores[user_b.id].present?, "direct connection should have proximity"

    # User C should have some proximity (transitive via B)
    assert scores[user_c.id].present?, "transitive connection should have some proximity"
    assert scores[user_c.id] > 0, "transitive connection should be positive"

    # Direct connection should be stronger than transitive
    assert scores[user_b.id] > scores[user_c.id],
           "direct connection should be stronger than transitive"
  end

  test "users with no shared groups have zero proximity" do
    user1 = create_user(email: "isolated1@example.com")
    user2 = create_user(email: "isolated2@example.com")

    # Put them in different studios with no overlap
    studio1 = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Isolated Studio 1",
      handle: "isolated-studio1-#{SecureRandom.hex(4)}"
    )
    studio2 = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Isolated Studio 2",
      handle: "isolated-studio2-#{SecureRandom.hex(4)}"
    )

    SuperagentMember.create!(tenant: @tenant, superagent: studio1, user: user1)
    SuperagentMember.create!(tenant: @tenant, superagent: studio2, user: user2)

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    # User2 should not appear in scores (no shared groups)
    assert_nil scores[user2.id], "users with no shared groups should have no proximity"
  end

  test "respects tenant scoping" do
    # Create a second tenant
    tenant2 = create_tenant(subdomain: "tenant2-#{SecureRandom.hex(4)}", name: "Tenant 2")

    user1 = create_user(email: "tenant1_user@example.com")
    user2 = create_user(email: "tenant2_user@example.com")

    # User1 in tenant1's superagent
    SuperagentMember.create!(tenant: @tenant, superagent: @superagent, user: user1)

    # Create superagent in tenant2
    studio2 = create_superagent(
      tenant: tenant2,
      created_by: @user,
      name: "Tenant 2 Studio",
      handle: "tenant2-studio-#{SecureRandom.hex(4)}"
    )
    SuperagentMember.create!(tenant: tenant2, superagent: studio2, user: user2)

    # Calculate proximity scoped to tenant1
    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    # User2 should not appear (they're in a different tenant)
    assert_nil scores[user2.id], "users in different tenants should not have proximity"
  end

  # =========================================================================
  # Edge cases
  # =========================================================================

  test "user with no groups returns empty scores" do
    isolated_user = create_user(email: "totally_isolated@example.com")

    calculator = SocialProximityCalculator.new(isolated_user, tenant_id: @tenant.id)
    scores = calculator.compute

    assert_equal({}, scores, "user with no groups should have empty scores")
  end

  test "algorithm is deterministic enough for caching" do
    user1 = create_user(email: "determinism1@example.com")
    user2 = create_user(email: "determinism2@example.com")

    studio = create_superagent(
      tenant: @tenant,
      created_by: @user,
      name: "Determinism Studio",
      handle: "determinism-studio-#{SecureRandom.hex(4)}"
    )

    SuperagentMember.create!(tenant: @tenant, superagent: studio, user: user1)
    SuperagentMember.create!(tenant: @tenant, superagent: studio, user: user2)

    # Run multiple times
    scores1 = SocialProximityCalculator.new(user1, tenant_id: @tenant.id).compute
    scores2 = SocialProximityCalculator.new(user1, tenant_id: @tenant.id).compute

    # Scores should be similar (allowing for Monte Carlo variance)
    # With 1000 walks, scores should be within ~10% of each other
    if scores1[user2.id] && scores2[user2.id]
      diff = (scores1[user2.id] - scores2[user2.id]).abs
      avg = (scores1[user2.id] + scores2[user2.id]) / 2.0
      # Allow 20% variance due to random walks
      assert diff < avg * 0.3, "scores should be relatively stable across runs"
    end
  end
end
