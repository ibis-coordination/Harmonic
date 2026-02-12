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

  test "requires user parameter" do
    # Sorbet enforces the type at runtime, so passing nil raises TypeError
    assert_raises TypeError do
      CommitmentParticipantManager.new(commitment: @commitment, user: nil)
    end
  end

  test "requires commitment parameter" do
    # Sorbet enforces the type at runtime, so passing nil raises TypeError
    assert_raises TypeError do
      CommitmentParticipantManager.new(commitment: nil, user: @user)
    end
  end

  # === Find or Create Participant Tests ===

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

  # === Idempotency Tests ===

  test "calling find_or_create_participant multiple times is idempotent" do
    new_user = create_user(email: "idempotent_commit_#{SecureRandom.hex(4)}@example.com")
    manager = CommitmentParticipantManager.new(commitment: @commitment, user: new_user)

    first_participant = manager.find_or_create_participant
    second_participant = manager.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end

  test "different manager instances for same user return same participant" do
    new_user = create_user(email: "same_user_commit_#{SecureRandom.hex(4)}@example.com")
    manager1 = CommitmentParticipantManager.new(commitment: @commitment, user: new_user)
    manager2 = CommitmentParticipantManager.new(commitment: @commitment, user: new_user)

    first_participant = manager1.find_or_create_participant
    second_participant = manager2.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end

  # === Commitment-specific behavior ===

  test "new commitment participant is not committed by default" do
    new_user = create_user(email: "uncommitted_#{SecureRandom.hex(4)}@example.com")
    manager = CommitmentParticipantManager.new(commitment: @commitment, user: new_user)

    participant = manager.find_or_create_participant
    assert_not participant.committed?
  end
end
