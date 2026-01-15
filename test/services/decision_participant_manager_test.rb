require "test_helper"

class DecisionParticipantManagerTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    @decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
  end

  # === Initialization Tests ===

  test "can be initialized with decision and user" do
    manager = DecisionParticipantManager.new(decision: @decision, user: @user)
    assert_not_nil manager
  end

  test "can be initialized with decision and participant_uid" do
    manager = DecisionParticipantManager.new(decision: @decision, participant_uid: "test-uid-123")
    assert_not_nil manager
  end

  test "can be initialized with decision only" do
    manager = DecisionParticipantManager.new(decision: @decision)
    assert_not_nil manager
  end

  # === Find or Create by User Tests ===

  test "find_or_create_participant creates participant for new user" do
    new_user = create_user(email: "new_participant_#{SecureRandom.hex(4)}@example.com")
    manager = DecisionParticipantManager.new(decision: @decision, user: new_user)

    assert_difference -> { DecisionParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert participant.persisted?
      assert_equal @decision, participant.decision
      assert_equal new_user, participant.user
      assert participant.participant_uid.present?
    end
  end

  test "find_or_create_participant returns existing participant for user" do
    new_user = create_user(email: "existing_participant_#{SecureRandom.hex(4)}@example.com")
    existing_participant = DecisionParticipant.create!(
      decision: @decision,
      user: new_user,
      participant_uid: SecureRandom.uuid
    )

    manager = DecisionParticipantManager.new(decision: @decision, user: new_user)

    assert_no_difference -> { DecisionParticipant.count } do
      participant = manager.find_or_create_participant
      assert_equal existing_participant.id, participant.id
    end
  end

  test "find_or_create_participant ignores participant_uid when user provided" do
    new_user = create_user(email: "uid_ignored_#{SecureRandom.hex(4)}@example.com")
    # Create a participant with the given uid but no user
    uid = SecureRandom.uuid
    DecisionParticipant.create!(
      decision: @decision,
      user: nil,
      participant_uid: uid
    )

    # When user is provided, it should create a new participant for the user
    # not find the anonymous one
    manager = DecisionParticipantManager.new(decision: @decision, user: new_user, participant_uid: uid)

    participant = manager.find_or_create_participant
    assert_equal new_user, participant.user
    # Participant_uid should be different (newly generated)
  end

  # === Find or Create by Participant UID Tests ===

  test "find_or_create_participant creates anonymous participant with uid" do
    uid = SecureRandom.uuid
    manager = DecisionParticipantManager.new(decision: @decision, participant_uid: uid)

    assert_difference -> { DecisionParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert participant.persisted?
      assert_equal @decision, participant.decision
      assert_nil participant.user
      assert_equal uid, participant.participant_uid
    end
  end

  test "find_or_create_participant returns existing anonymous participant" do
    uid = SecureRandom.uuid
    existing_participant = DecisionParticipant.create!(
      decision: @decision,
      user: nil,
      participant_uid: uid
    )

    manager = DecisionParticipantManager.new(decision: @decision, participant_uid: uid)

    assert_no_difference -> { DecisionParticipant.count } do
      participant = manager.find_or_create_participant
      assert_equal existing_participant.id, participant.id
    end
  end

  test "find_or_create_participant generates new uid when existing uid has user" do
    uid = SecureRandom.uuid
    # Create a participant with user and uid
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    DecisionParticipant.create!(
      decision: @decision,
      user: other_user,
      participant_uid: uid
    )

    # Anonymous request with same uid should get a new participant
    manager = DecisionParticipantManager.new(decision: @decision, participant_uid: uid)

    assert_difference -> { DecisionParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert_nil participant.user
      assert_not_equal uid, participant.participant_uid
    end
  end

  # === Auto-Generate UID Tests ===

  test "find_or_create_participant generates uid when none provided" do
    manager = DecisionParticipantManager.new(decision: @decision)

    assert_difference -> { DecisionParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert participant.persisted?
      assert participant.participant_uid.present?
      assert_nil participant.user
    end
  end

  # === Name Parameter Tests ===

  test "find_or_create_participant sets name on new participant" do
    manager = DecisionParticipantManager.new(
      decision: @decision,
      participant_uid: SecureRandom.uuid,
      name: "Anonymous Voter"
    )

    participant = manager.find_or_create_participant
    assert_equal "Anonymous Voter", participant.name
  end

  test "find_or_create_participant sets name for user participant" do
    new_user = create_user(email: "named_user_#{SecureRandom.hex(4)}@example.com")
    manager = DecisionParticipantManager.new(
      decision: @decision,
      user: new_user,
      name: "Custom Name"
    )

    participant = manager.find_or_create_participant
    assert_equal "Custom Name", participant.name
  end

  # === Error Handling Tests ===

  test "find_or_create_participant raises error without decision" do
    # Sorbet enforces the type at runtime, so passing nil raises TypeError
    assert_raises TypeError do
      DecisionParticipantManager.new(decision: nil, user: @user)
    end
  end

  # === Idempotency Tests ===

  test "calling find_or_create_participant multiple times is idempotent for user" do
    new_user = create_user(email: "idempotent_#{SecureRandom.hex(4)}@example.com")
    manager = DecisionParticipantManager.new(decision: @decision, user: new_user)

    first_participant = manager.find_or_create_participant
    second_participant = manager.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end

  test "calling find_or_create_participant multiple times is idempotent for uid" do
    uid = SecureRandom.uuid
    manager = DecisionParticipantManager.new(decision: @decision, participant_uid: uid)

    first_participant = manager.find_or_create_participant

    # Create new manager with same uid
    manager2 = DecisionParticipantManager.new(decision: @decision, participant_uid: uid)
    second_participant = manager2.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end
end
