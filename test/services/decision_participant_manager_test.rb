require "test_helper"

class DecisionParticipantManagerTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
  end

  # === Initialization Tests ===

  test "can be initialized with decision and user" do
    manager = DecisionParticipantManager.new(decision: @decision, user: @user)
    assert_not_nil manager
  end

  test "requires user parameter" do
    # Sorbet enforces the type at runtime, so passing nil raises TypeError
    assert_raises TypeError do
      DecisionParticipantManager.new(decision: @decision, user: nil)
    end
  end

  test "requires decision parameter" do
    # Sorbet enforces the type at runtime, so passing nil raises TypeError
    assert_raises TypeError do
      DecisionParticipantManager.new(decision: nil, user: @user)
    end
  end

  # === Find or Create Participant Tests ===

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

  # === Name Parameter Tests ===

  test "find_or_create_participant sets name on new participant" do
    new_user = create_user(email: "named_user_#{SecureRandom.hex(4)}@example.com")
    manager = DecisionParticipantManager.new(
      decision: @decision,
      user: new_user,
      name: "Custom Name"
    )

    participant = manager.find_or_create_participant
    assert_equal "Custom Name", participant.name
  end

  # === Idempotency Tests ===

  test "calling find_or_create_participant multiple times is idempotent" do
    new_user = create_user(email: "idempotent_#{SecureRandom.hex(4)}@example.com")
    manager = DecisionParticipantManager.new(decision: @decision, user: new_user)

    first_participant = manager.find_or_create_participant
    second_participant = manager.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end

  test "different manager instances for same user return same participant" do
    new_user = create_user(email: "same_user_#{SecureRandom.hex(4)}@example.com")
    manager1 = DecisionParticipantManager.new(decision: @decision, user: new_user)
    manager2 = DecisionParticipantManager.new(decision: @decision, user: new_user)

    first_participant = manager1.find_or_create_participant
    second_participant = manager2.find_or_create_participant

    assert_equal first_participant.id, second_participant.id
  end
end
