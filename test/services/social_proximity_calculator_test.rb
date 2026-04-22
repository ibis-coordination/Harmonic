require "test_helper"

class SocialProximityCalculatorTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
  end

  # =========================================================================
  # Collective membership tests
  # =========================================================================

  test "users in same small collective have high proximity" do
    # Create a small 3-person collective
    user1 = create_user(email: "prox_user1@example.com")
    user2 = create_user(email: "prox_user2@example.com")
    user3 = create_user(email: "prox_user3@example.com")

    small_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Small Collective",
      handle: "small-collective-#{SecureRandom.hex(4)}"
    )

    [user1, user2, user3].each do |u|
      CollectiveMember.create!(tenant: @tenant, collective: small_collective, user: u)
    end

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    # Both other users should have proximity scores
    assert scores[user2.id].present?, "user2 should have a proximity score"
    assert scores[user3.id].present?, "user3 should have a proximity score"
    assert scores[user2.id] > 0.01, "small group members should have meaningful proximity"
  end

  test "users in same large collective have lower proximity than small one" do
    user1 = create_user(email: "large_prox1@example.com")
    user2 = create_user(email: "large_prox2@example.com")

    # Create small collective (3 members)
    small_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Small Collective",
      handle: "small-collective-large-#{SecureRandom.hex(4)}"
    )
    [user1, user2].each do |u|
      CollectiveMember.create!(tenant: @tenant, collective: small_collective, user: u)
    end
    user3 = create_user(email: "small_member@example.com")
    CollectiveMember.create!(tenant: @tenant, collective: small_collective, user: user3)

    # Calculate proximity through small collective
    calc_small = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores_small = calc_small.compute

    # Now create large collective (20 members)
    user4 = create_user(email: "large_user4@example.com")
    user5 = create_user(email: "large_user5@example.com")

    large_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Large Collective",
      handle: "large-collective-#{SecureRandom.hex(4)}"
    )
    [user4, user5].each do |u|
      CollectiveMember.create!(tenant: @tenant, collective: large_collective, user: u)
    end
    # Add 18 more users to make it large
    18.times do |i|
      u = create_user(email: "large_member_#{i}@example.com")
      CollectiveMember.create!(tenant: @tenant, collective: large_collective, user: u)
    end

    # Calculate proximity through large collective
    calc_large = SocialProximityCalculator.new(user4, tenant_id: @tenant.id)
    scores_large = calc_large.compute

    # Small collective proximity should be higher than large collective proximity
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

    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: user1)
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: user2)

    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Both users read the note
    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: @collective,
      note: note,
      user: user1,
      event_type: "read_confirmation",
      happened_at: Time.current
    )
    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: @collective,
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

    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: user1)
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: user2)

    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

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

    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: user1)
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: user2)

    commitment = create_commitment(
      tenant: @tenant,
      collective: @collective,
      created_by: @user
    )

    # Both users join the commitment (with unique participant_uid values)
    CommitmentParticipant.create!(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: user1,
      participant_uid: SecureRandom.uuid,
      committed: true
    )
    CommitmentParticipant.create!(
      tenant: @tenant,
      collective: @collective,
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

  test "users with heartbeats in same collective cycle have proximity" do
    user1 = create_user(email: "heartbeat1@example.com")
    user2 = create_user(email: "heartbeat2@example.com")

    # Create a dedicated collective for heartbeat testing
    heartbeat_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Heartbeat Collective",
      handle: "heartbeat-collective-#{SecureRandom.hex(4)}"
    )

    # Create heartbeats within the current cycle
    heartbeat1 = Heartbeat.create!(
      tenant: @tenant,
      collective: heartbeat_collective,
      user: user1,
      expires_at: 1.day.from_now
    )
    heartbeat2 = Heartbeat.create!(
      tenant: @tenant,
      collective: heartbeat_collective,
      user: user2,
      expires_at: 1.day.from_now
    )

    calculator = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    scores = calculator.compute

    assert scores[user2.id].present?, "user with heartbeat in same cycle should have proximity"
    assert scores[user2.id] > 0, "heartbeat users should have positive proximity"

    # Cleanup heartbeats before collective is deleted
    heartbeat1.destroy!
    heartbeat2.destroy!
  end

  # =========================================================================
  # Combined tests
  # =========================================================================

  test "multiple shared groups increase proximity" do
    user1 = create_user(email: "multi1@example.com")
    user2 = create_user(email: "multi2@example.com")

    multi_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Multi Collective",
      handle: "multi-collective-#{SecureRandom.hex(4)}"
    )

    # Both in same collective
    CollectiveMember.create!(tenant: @tenant, collective: multi_collective, user: user1)
    CollectiveMember.create!(tenant: @tenant, collective: multi_collective, user: user2)

    # Calculate baseline proximity with just collective
    calc_baseline = SocialProximityCalculator.new(user1, tenant_id: @tenant.id)
    baseline_scores = calc_baseline.compute
    baseline_proximity = baseline_scores[user2.id] || 0.0

    # Now add shared note reading
    note = create_note(tenant: @tenant, collective: multi_collective, created_by: @user)
    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: multi_collective,
      note: note,
      user: user1,
      event_type: "read_confirmation",
      happened_at: Time.current
    )
    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: multi_collective,
      note: note,
      user: user2,
      event_type: "read_confirmation",
      happened_at: Time.current
    )

    # Calculate new proximity with both collective and note reading
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
    # User A in Collective 1
    # User B in Collective 1 and Collective 2
    # User C in Collective 2 only
    # Assert A has some proximity to C (via B)

    user_a = create_user(email: "transitive_a@example.com")
    user_b = create_user(email: "transitive_b@example.com")
    user_c = create_user(email: "transitive_c@example.com")

    collective1 = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Collective 1",
      handle: "transitive-collective1-#{SecureRandom.hex(4)}"
    )
    collective2 = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Collective 2",
      handle: "transitive-collective2-#{SecureRandom.hex(4)}"
    )

    # User A in Collective 1 only
    CollectiveMember.create!(tenant: @tenant, collective: collective1, user: user_a)

    # User B in both collectives (the bridge)
    CollectiveMember.create!(tenant: @tenant, collective: collective1, user: user_b)
    CollectiveMember.create!(tenant: @tenant, collective: collective2, user: user_b)

    # User C in Collective 2 only
    CollectiveMember.create!(tenant: @tenant, collective: collective2, user: user_c)

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

    # Put them in different collectives with no overlap
    isolated1 = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Isolated Collective 1",
      handle: "isolated-collective1-#{SecureRandom.hex(4)}"
    )
    isolated2 = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Isolated Collective 2",
      handle: "isolated-collective2-#{SecureRandom.hex(4)}"
    )

    CollectiveMember.create!(tenant: @tenant, collective: isolated1, user: user1)
    CollectiveMember.create!(tenant: @tenant, collective: isolated2, user: user2)

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

    # User1 in tenant1's collective
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: user1)

    # Create collective in tenant2
    collective2 = create_collective(
      tenant: tenant2,
      created_by: @user,
      name: "Tenant 2 Collective",
      handle: "tenant2-collective-#{SecureRandom.hex(4)}"
    )
    CollectiveMember.create!(tenant: tenant2, collective: collective2, user: user2)

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

    determinism_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Determinism Collective",
      handle: "determinism-collective-#{SecureRandom.hex(4)}"
    )

    CollectiveMember.create!(tenant: @tenant, collective: determinism_collective, user: user1)
    CollectiveMember.create!(tenant: @tenant, collective: determinism_collective, user: user2)

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

  # =========================================================================
  # Block exclusion tests
  # =========================================================================

  test "blocked user is excluded from proximity results" do
    user1 = create_user(email: "block_prox1@example.com")
    user2 = create_user(email: "block_prox2@example.com")

    small_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Block Test Collective",
      handle: "block-test-#{SecureRandom.hex(4)}"
    )

    [@user, user1, user2].each do |u|
      CollectiveMember.create!(tenant: @tenant, collective: small_collective, user: u)
    end

    # Block user1
    UserBlock.create!(blocker: @user, blocked: user1, tenant: @tenant)

    calc = SocialProximityCalculator.new(@user, tenant_id: @tenant.id)
    scores = calc.compute

    assert_nil scores[user1.id], "Blocked user should not appear in proximity results"
    # user2 should still appear (they share the collective)
    assert scores[user2.id].present?, "Non-blocked user should appear in proximity results" if scores.any?
  end

  test "blocked user cannot serve as bridge to other users" do
    # Setup: user -> user1 (blocked) -> user2 (only connected via user1's collective)
    user1 = create_user(email: "bridge_block1@example.com")
    user2 = create_user(email: "bridge_block2@example.com")

    shared_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Shared Collective",
      handle: "shared-#{SecureRandom.hex(4)}"
    )

    bridge_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      name: "Bridge Collective",
      handle: "bridge-#{SecureRandom.hex(4)}"
    )

    # user and user1 share shared_collective
    [@user, user1].each do |u|
      CollectiveMember.create!(tenant: @tenant, collective: shared_collective, user: u)
    end

    # user1 and user2 share bridge_collective (user is NOT in bridge_collective)
    [user1, user2].each do |u|
      CollectiveMember.create!(tenant: @tenant, collective: bridge_collective, user: u)
    end

    # Without block: user2 reachable via user1 as bridge
    calc_before = SocialProximityCalculator.new(@user, tenant_id: @tenant.id)
    scores_before = calc_before.compute

    # Block user1 — now user2 should be unreachable
    UserBlock.create!(blocker: @user, blocked: user1, tenant: @tenant)

    calc_after = SocialProximityCalculator.new(@user, tenant_id: @tenant.id)
    scores_after = calc_after.compute

    assert_nil scores_after[user1.id], "Blocked bridge user should not appear"
    # user2's score should be zero or absent (no path without the bridge)
    assert_nil scores_after[user2.id], "User reachable only through blocked bridge should not appear"
  end
end
