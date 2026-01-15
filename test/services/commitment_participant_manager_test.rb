require "test_helper"

class CommitmentParticipantManagerTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    @commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user)
  end

  # === Initialization Tests ===

  test "can be initialized with commitment and user" do
    manager = CommitmentParticipantManager.new(commitment: @commitment, user: @user)
    assert_not_nil manager
  end

  test "can be initialized with commitment and participant_uid" do
    manager = CommitmentParticipantManager.new(commitment: @commitment, participant_uid: "test-uid-123")
    assert_not_nil manager
  end

  test "can be initialized with commitment only" do
    manager = CommitmentParticipantManager.new(commitment: @commitment)
    assert_not_nil manager
  end

  # === Find or Create by User Tests ===

  test "find_or_create_participant creates participant for new user" do
    new_user = create_user(email: "new_committer_#{SecureRandom.hex(4)}@example.com")
    manager = CommitmentParticipantManager.new(commitment: @commitment, user: new_user)

    assert_difference -> { CommitmentParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert participant.persisted?
      assert_equal @commitment, participant.commitment
      assert_equal new_user, participant.user
      assert participant.participant_uid.present?
    end
  end

  test "find_or_create_participant returns existing participant for user" do
    new_user = create_user(email: "existing_committer_#{SecureRandom.hex(4)}@example.com")
    existing_participant = CommitmentParticipant.create!(
      commitment: @commitment,
      user: new_user,
      participant_uid: SecureRandom.uuid
    )

    manager = CommitmentParticipantManager.new(commitment: @commitment, user: new_user)

    assert_no_difference -> { CommitmentParticipant.count } do
      participant = manager.find_or_create_participant
      assert_equal existing_participant.id, participant.id
    end
  end

  test "find_or_create_participant ignores participant_uid when user provided" do
    new_user = create_user(email: "uid_ignored_commit_#{SecureRandom.hex(4)}@example.com")
    # Create a participant with the given uid but no user
    uid = SecureRandom.uuid
    CommitmentParticipant.create!(
      commitment: @commitment,
      user: nil,
      participant_uid: uid
    )

    # When user is provided, it should create a new participant for the user
    manager = CommitmentParticipantManager.new(commitment: @commitment, user: new_user, participant_uid: uid)

    participant = manager.find_or_create_participant
    assert_equal new_user, participant.user
  end

  # === Find or Create by Participant UID Tests ===

  test "find_or_create_participant creates anonymous participant with uid" do
    uid = SecureRandom.uuid
    manager = CommitmentParticipantManager.new(commitment: @commitment, participant_uid: uid)

    assert_difference -> { CommitmentParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert participant.persisted?
      assert_equal @commitment, participant.commitment
      assert_nil participant.user
      assert_equal uid, participant.participant_uid
    end
  end

  test "find_or_create_participant returns existing anonymous participant" do
    uid = SecureRandom.uuid
    existing_participant = CommitmentParticipant.create!(
      commitment: @commitment,
      user: nil,
      participant_uid: uid
    )

    manager = CommitmentParticipantManager.new(commitment: @commitment, participant_uid: uid)

    assert_no_difference -> { CommitmentParticipant.count } do
      participant = manager.find_or_create_participant
      assert_equal existing_participant.id, participant.id
    end
  end

  test "find_or_create_participant generates new uid when existing uid has user" do
    uid = SecureRandom.uuid
    # Create a participant with user and uid
    other_user = create_user(email: "other_commit_#{SecureRandom.hex(4)}@example.com")
    CommitmentParticipant.create!(
      commitment: @commitment,
      user: other_user,
      participant_uid: uid
    )

    # Anonymous request with same uid should get a new participant
    manager = CommitmentParticipantManager.new(commitment: @commitment, participant_uid: uid)

    assert_difference -> { CommitmentParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert_nil participant.user
      assert_not_equal uid, participant.participant_uid
    end
  end

  # === Auto-Generate UID Tests ===

  test "find_or_create_participant generates uid when none provided" do
    manager = CommitmentParticipantManager.new(commitment: @commitment)

    assert_difference -> { CommitmentParticipant.count }, 1 do
      participant = manager.find_or_create_participant
      assert participant.persisted?
      assert participant.participant_uid.present?
      assert_nil participant.user
    end
  end

  # === Name Parameter Tests ===

  test "find_or_create_participant sets name on new participant" do
    manager = CommitmentParticipantManager.new(
      commitment: @commitment,
      participant_uid: SecureRandom.uuid,
      name: "Anonymous Committer"
    )

    participant = manager.find_or_create_participant
    assert_equal "Anonymous Committer", participant.name
  end

  test "find_or_create_participant sets name for user participant" do
    new_user = create_user(email: "named_committer_#{SecureRandom.hex(4)}@example.com")
    manager = CommitmentParticipantManager.new(
      commitment: @commitment,
      user: new_user,
      name: "Custom Name"
    )

    participant = manager.find_or_create_participant
    assert_equal "Custom Name", participant.name
  end

  # === Error Handling Tests ===

  test "find_or_create_participant raises error without commitment" do
    # Sorbet enforces the type at runtime, so passing nil raises TypeError
    assert_raises TypeError do
      CommitmentParticipantManager.new(commitment: nil, user: @user)
    end
  end

  # === Idempotency Tests ===

  test "calling find_or_create_participant multiple times is idempotent for user" do
    new_user = create_user(email: "idempotent_commit_#{SecureRandom.hex(4)}@example.com")
    manager = CommitmentParticipantManager.new(commitment: @commitment, user: new_user)

    first_participant = manager.find_or_create_participant
    second_participant = manager.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end

  test "calling find_or_create_participant multiple times is idempotent for uid" do
    uid = SecureRandom.uuid
    manager = CommitmentParticipantManager.new(commitment: @commitment, participant_uid: uid)

    first_participant = manager.find_or_create_participant

    # Create new manager with same uid
    manager2 = CommitmentParticipantManager.new(commitment: @commitment, participant_uid: uid)
    second_participant = manager2.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end

  # === Difference from DecisionParticipantManager ===
  # CommitmentParticipant has additional fields like `committed` that DecisionParticipant doesn't have

  test "new commitment participant is not committed by default" do
    manager = CommitmentParticipantManager.new(
      commitment: @commitment,
      participant_uid: SecureRandom.uuid
    )

    participant = manager.find_or_create_participant
    # Check default committed state (may be nil or false depending on schema)
    assert_not participant.committed?
  end
end
