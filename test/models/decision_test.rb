require "test_helper"

class DecisionTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @studio = @global_studio
    @user = @global_user
  end

  def create_decision
    Decision.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      updated_by: @user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: true,
      deadline: Time.now + 1.day
    )
  end

  test "Decision.create works" do
    decision = create_decision

    assert decision.persisted?
    assert_equal "Test Decision", decision.question
    assert_equal "This is a test decision.", decision.description
    assert_equal @tenant, decision.tenant
    assert_equal @studio, decision.studio
    assert_equal @user, decision.created_by
    assert_equal @user, decision.updated_by
    assert decision.options_open
  end

  test "Decision requires a question" do
    decision = Decision.new(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      updated_by: @user,
      description: "This is a test decision without a question.",
      deadline: Time.now + 1.day
    )

    assert_not decision.valid?
    assert_includes decision.errors[:question], "can't be blank"
  end

  test "Decision requires a deadline" do
    decision = Decision.new(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      updated_by: @user,
      question: 'No deadline?',
      description: "This is a test decision without a deadline."
    )

    assert_not decision.valid?
    assert_includes decision.errors[:deadline], "can't be blank"
  end

  test "Decision.voter_count returns the correct count" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    option = Option.create!(decision: decision, title: "Test Option", decision_participant: participant)
    [1, 2, 3].each do |i|
      user = create_user(email: "u#{i}@example.com")
      participant = DecisionParticipant.create!(decision: decision, user: @user, participant_uid: "u#{i}")
      Approval.create!(decision: decision, decision_participant: participant, option: option, value: true, stars: 0)
      assert_equal i, decision.voter_count
    end
  end

  test "Decision.results returns the correct results" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    options = [
      Option.create!(decision: decision, title: "Option 1", decision_participant: participant),
      Option.create!(decision: decision, title: "Option 2", decision_participant: participant)
    ]
    approval1 = Approval.create!(decision: decision, decision_participant: participant, option: options.first, value: true, stars: 0)
    approval2 = Approval.create!(decision: decision, decision_participant: participant, option: options.last, value: false, stars: 1)
    results = decision.results
    assert_equal 2, results.size
    assert_equal options.first.id, results[0][:option_id]
    assert_equal options.last.id, results[1][:option_id]
    assert_equal 1, results[0].approved_yes
    assert_equal 0, results[1].approved_yes
    assert_equal 0, results[0].approved_no
    assert_equal 1, results[1].approved_no
    assert_equal 0, results[0].stars
    assert_equal 1, results[1].stars
  end

  test "Decision.can_add_options? returns true for creator" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    assert decision.can_add_options?(participant)
  end

  test "Decision.can_add_options? returns false for non-creator when options are closed" do
    decision = create_decision
    decision.options_open = false
    decision.save!
    non_creator = create_user(email: "non_creator@example.com", name: "Non-Creator")
    participant = DecisionParticipant.create!(decision: decision, user: non_creator)
    assert_not decision.can_add_options?(participant)
  end

  test "Decision.can_add_options? returns true for non-creator when options are open" do
    decision = create_decision
    non_creator = create_user(email: "non_creator@example.com", name: "Non-Creator")
    participant = DecisionParticipant.create!(decision: decision, user: non_creator)
    assert decision.can_add_options?(participant)
  end

  test "Decision.api_json includes expected fields" do
    decision = create_decision
    json = decision.api_json
    assert_equal decision.id, json[:id]
    assert_equal decision.question, json[:question]
    assert_equal decision.description, json[:description]
    assert_equal decision.options_open, json[:options_open]
    assert_equal decision.created_at, json[:created_at]
    assert_equal decision.updated_at, json[:updated_at]
  end

  # === Deadline Status Tests ===

  test "Decision with future deadline is not closed" do
    decision = create_decision
    assert_not decision.closed?
  end

  test "Decision with past deadline is closed" do
    decision = Decision.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      updated_by: @user,
      question: "Closed Decision",
      description: "Test description",
      deadline: 1.day.ago
    )

    assert decision.closed?
  end

  # === Option Tests ===

  test "Decision can have multiple options" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)

    option1 = Option.create!(decision: decision, title: "Option A", decision_participant: participant)
    option2 = Option.create!(decision: decision, title: "Option B", decision_participant: participant)
    option3 = Option.create!(decision: decision, title: "Option C", decision_participant: participant)

    assert_equal 3, decision.options.count
  end

  test "Decision.options_open can be set to false" do
    decision = create_decision
    assert decision.options_open

    decision.options_open = false
    decision.save!
    assert_not decision.options_open
  end

  # === Participant Tests ===

  test "Decision creates participant for voter" do
    decision = create_decision
    new_user = create_user(email: "voter_#{SecureRandom.hex(4)}@example.com")

    participant = DecisionParticipant.create!(decision: decision, user: new_user)
    assert participant.persisted?
    assert_equal decision, participant.decision
    assert_equal new_user, participant.user
  end

  # === Approval and Star Tests ===

  test "Approval can have stars" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    option = Option.create!(decision: decision, title: "Starred Option", decision_participant: participant)

    approval = Approval.create!(
      decision: decision,
      decision_participant: participant,
      option: option,
      value: true,
      stars: 1
    )

    assert_equal 1, approval.stars
  end

  test "Decision.results includes star counts" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    option = Option.create!(decision: decision, title: "Star Test Option", decision_participant: participant)

    Approval.create!(
      decision: decision,
      decision_participant: participant,
      option: option,
      value: true,
      stars: 1
    )

    results = decision.results
    assert_equal 1, results.first.stars
  end

  # === Pin Tests ===

  test "Decision can be pinned" do
    decision = create_decision
    decision.pin!(tenant: @tenant, studio: @studio, user: @user)
    assert decision.is_pinned?(tenant: @tenant, studio: @studio, user: @user)
  end

  test "Decision can be unpinned" do
    decision = create_decision
    decision.pin!(tenant: @tenant, studio: @studio, user: @user)
    decision.unpin!(tenant: @tenant, studio: @studio, user: @user)
    assert_not decision.is_pinned?(tenant: @tenant, studio: @studio, user: @user)
  end
end
