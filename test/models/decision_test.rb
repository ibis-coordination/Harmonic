require "test_helper"

class DecisionTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
  end

  def create_decision
    Decision.create!(
      tenant: @tenant,
      collective: @collective,
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
    assert_equal @collective, decision.collective
    assert_equal @user, decision.created_by
    assert_equal @user, decision.updated_by
    assert decision.options_open
  end

  test "Decision requires a question" do
    decision = Decision.new(
      tenant: @tenant,
      collective: @collective,
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
      collective: @collective,
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
      Vote.create!(decision: decision, decision_participant: participant, option: option, accepted: 1, preferred: 0)
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
    vote1 = Vote.create!(decision: decision, decision_participant: participant, option: options.first, accepted: 1, preferred: 0)
    vote2 = Vote.create!(decision: decision, decision_participant: participant, option: options.last, accepted: 0, preferred: 1)
    results = decision.results
    assert_equal 2, results.size
    assert_equal options.first.id, results[0][:option_id]
    assert_equal options.last.id, results[1][:option_id]
    assert_equal 1, results[0].accepted_yes
    assert_equal 0, results[1].accepted_yes
    assert_equal 0, results[0].accepted_no
    assert_equal 1, results[1].accepted_no
    assert_equal 0, results[0].preferred
    assert_equal 1, results[1].preferred
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
      collective: @collective,
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

  # === Vote and Preference Tests ===

  test "Vote can have preference" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    option = Option.create!(decision: decision, title: "Preferred Option", decision_participant: participant)

    vote = Vote.create!(
      decision: decision,
      decision_participant: participant,
      option: option,
      accepted: 1,
      preferred: 1
    )

    assert_equal 1, vote.preferred
  end

  test "Decision.results includes preference counts" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    option = Option.create!(decision: decision, title: "Preference Test Option", decision_participant: participant)

    Vote.create!(
      decision: decision,
      decision_participant: participant,
      option: option,
      accepted: 1,
      preferred: 1
    )

    results = decision.results
    assert_equal 1, results.first.preferred
  end

  # === Pin Tests ===

  test "Decision can be pinned" do
    decision = create_decision
    decision.pin!(tenant: @tenant, collective: @collective, user: @user)
    assert decision.is_pinned?(tenant: @tenant, collective: @collective, user: @user)
  end

  test "Decision can be unpinned" do
    decision = create_decision
    decision.pin!(tenant: @tenant, collective: @collective, user: @user)
    decision.unpin!(tenant: @tenant, collective: @collective, user: @user)
    assert_not decision.is_pinned?(tenant: @tenant, collective: @collective, user: @user)
  end

  # Subtype tests

  test "Decision defaults to vote subtype" do
    decision = create_decision

    assert_equal "vote", decision.subtype
    assert decision.is_vote?
    assert_not decision.is_lottery?
    assert_not decision.is_executive?
  end

  test "Decision can be created with explicit subtype" do
    Decision::SUBTYPES.each do |subtype|
      decision = Decision.create!(
        tenant: @tenant,
        collective: @collective,
        created_by: @user,
        updated_by: @user,
        question: "#{subtype} decision",
        description: "Test description",
        deadline: 1.day.from_now,
        subtype: subtype,
      )

      assert_equal subtype, decision.subtype
    end
  end

  test "Decision rejects invalid subtype" do
    decision = Decision.new(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      question: "Invalid subtype",
      deadline: 1.day.from_now,
      subtype: "invalid",
    )

    assert_not decision.valid?
    assert_includes decision.errors[:subtype], "is not included in the list"
  end

  test "Decision api_json includes subtype" do
    decision = Decision.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      question: "Lottery decision",
      description: "Test description",
      deadline: 1.day.from_now,
      subtype: "lottery",
    )

    json = decision.api_json
    assert_equal "lottery", json[:subtype]
  end

  # === Statementable Tests ===

  test "decision is statementable" do
    decision = create_decision
    assert decision.respond_to?(:statement)
    assert decision.respond_to?(:can_write_statement?)
  end

  test "creator can write statement" do
    decision = create_decision
    assert decision.can_write_statement?(@user)
  end

  test "non-creator cannot write statement" do
    decision = create_decision
    other_user = User.create!(name: "Other", email: "other-stmt-#{SecureRandom.hex(8)}@example.com", user_type: "human")
    assert_not decision.can_write_statement?(other_user)
  end

  test "decision can have one statement" do
    decision = create_decision
    statement = Note.create!(
      subtype: "statement",
      text: "We decided to go with Option A.",
      statementable: decision,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current,
    )
    assert_equal statement, decision.reload.statement
  end

  # === Executive Decision Tests ===

  test "is_executive? predicate" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Executive test?", description: "", deadline: 1.day.from_now,
      subtype: "executive",
    )
    assert decision.is_executive?
    assert_not decision.is_vote?
  end

  test "effective_decision_maker defaults to creator" do
    decision = create_decision
    assert_equal @user, decision.effective_decision_maker
  end

  test "effective_decision_maker returns designated decision maker" do
    other_user = User.create!(name: "Boss", email: "boss-#{SecureRandom.hex(8)}@example.com", user_type: "human")
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Who decides?", description: "", deadline: 1.day.from_now,
      subtype: "executive", decision_maker: other_user,
    )
    assert_equal other_user, decision.effective_decision_maker
  end

  test "executive decision: decision maker can close" do
    other_user = User.create!(name: "Boss", email: "boss-close-#{SecureRandom.hex(8)}@example.com", user_type: "human")
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Boss decides", description: "", deadline: 1.day.from_now,
      subtype: "executive", decision_maker: other_user,
    )
    assert decision.can_close?(other_user)
    assert_not decision.can_close?(@user)
  end

  test "executive decision: decision maker can write statement" do
    other_user = User.create!(name: "Boss", email: "boss-stmt-#{SecureRandom.hex(8)}@example.com", user_type: "human")
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Boss decides", description: "", deadline: 1.day.from_now,
      subtype: "executive", decision_maker: other_user,
    )
    assert decision.can_write_statement?(other_user)
    assert_not decision.can_write_statement?(@user)
  end

  test "executive decision: creator retains settings access" do
    other_user = User.create!(name: "Boss", email: "boss-settings-#{SecureRandom.hex(8)}@example.com", user_type: "human")
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Boss decides", description: "", deadline: 1.day.from_now,
      subtype: "executive", decision_maker: other_user,
    )
    assert decision.can_edit_settings?(@user)
    assert_not decision.can_edit_settings?(other_user)
  end

  # === Lottery Decision Tests ===

  test "is_lottery? predicate" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Lottery test?", description: "", deadline: 1.day.from_now,
      subtype: "lottery",
    )
    assert decision.is_lottery?
    assert_not decision.is_vote?
    assert_not decision.is_executive?
  end

  test "vote decision: can_close still uses creator" do
    decision = create_decision
    assert decision.can_close?(@user)
    other_user = User.create!(name: "Other", email: "other-close-#{SecureRandom.hex(8)}@example.com", user_type: "human")
    assert_not decision.can_close?(other_user)
  end

  test "decision can only have one statement" do
    decision = create_decision
    Note.create!(
      subtype: "statement",
      text: "First statement",
      statementable: decision,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current,
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      Note.create!(
        subtype: "statement",
        text: "Second statement",
        statementable: decision,
        created_by: @user,
        updated_by: @user,
        tenant: @tenant,
        collective: @collective,
        deadline: Time.current,
      )
    end
  end

  # === Verifiable Lottery Randomness Tests ===

  test "lottery_drawn? returns false when beacon not set" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Lottery drawn test?", description: "", deadline: 1.day.from_now,
      subtype: "lottery",
    )
    assert_not decision.lottery_drawn?
  end

  test "lottery_drawn? returns true when beacon is set" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Lottery drawn test?", description: "", deadline: 1.day.from_now,
      subtype: "lottery",
      lottery_beacon_round: 12345,
      lottery_beacon_randomness: "abc123",
    )
    assert decision.lottery_drawn?
  end

  test "lottery_drawn? returns false for non-lottery decisions" do
    decision = create_decision
    assert_not decision.lottery_drawn?
  end

  test "lottery results sorted by beacon-derived keys when drawn" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Verifiable lottery?", description: "", deadline: 1.minute.ago,
      subtype: "lottery",
      lottery_beacon_round: 100,
      lottery_beacon_randomness: "deadbeef",
    )
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Alpha", decision_participant: participant)
    Option.create!(decision: decision, title: "Beta", decision_participant: participant)
    Option.create!(decision: decision, title: "Gamma", decision_participant: participant)

    results = decision.results
    assert_equal 3, results.size

    # Verify sort keys are present and in descending order
    sort_keys = results.map(&:lottery_sort_key)
    assert sort_keys.all?(&:present?), "All results should have lottery_sort_key"
    assert_equal sort_keys, sort_keys.sort.reverse, "Results should be sorted by sort key descending"

    # Verify sort keys match manual SHA256 computation
    results.each do |result|
      expected = Digest::SHA256.hexdigest("deadbeef" + result.option_title.unicode_normalize(:nfc))
      assert_equal expected, result.lottery_sort_key
    end
  end

  test "vote decision results have nil lottery_sort_key" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Option A", decision_participant: participant)

    results = decision.results
    assert_nil results.first.lottery_sort_key
  end

  test "api_json includes beacon data for drawn lottery" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "API json test?", description: "", deadline: 1.day.from_now,
      subtype: "lottery",
      lottery_beacon_round: 99999,
      lottery_beacon_randomness: "abc123def456",
    )
    json = decision.api_json
    assert_equal 99999, json[:lottery_beacon_round]
    assert_equal "abc123def456", json[:lottery_beacon_randomness]
  end

  test "api_json omits beacon data for non-drawn lottery" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "API json test?", description: "", deadline: 1.day.from_now,
      subtype: "lottery",
    )
    json = decision.api_json
    assert_nil json[:lottery_beacon_round]
    assert_nil json[:lottery_beacon_randomness]
  end

  test "drawn lottery with single entry computes sort key" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Single entry?", description: "", deadline: 1.minute.ago,
      subtype: "lottery",
      lottery_beacon_round: 1,
      lottery_beacon_randomness: "abc",
    )
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Only Entry", decision_participant: participant)

    results = decision.results
    assert_equal 1, results.size
    assert results.first.lottery_sort_key.present?
  end

  test "drawn lottery with no entries returns empty results" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Empty lottery?", description: "", deadline: 1.minute.ago,
      subtype: "lottery",
      lottery_beacon_round: 1,
      lottery_beacon_randomness: "abc",
    )

    assert_equal 0, decision.results.size
  end

  test "drawn lottery result api_json includes lottery_sort_key" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "API sort key?", description: "", deadline: 1.minute.ago,
      subtype: "lottery",
      lottery_beacon_round: 1,
      lottery_beacon_randomness: "beacon123",
    )
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Test", decision_participant: participant)

    result_json = decision.results.first.api_json
    assert result_json[:lottery_sort_key].present?
    assert_equal 64, result_json[:lottery_sort_key].length
  end

  test "vote decision result api_json omits lottery_sort_key" do
    decision = create_decision
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Option A", decision_participant: participant)

    result_json = decision.results.first.api_json
    assert_nil result_json[:lottery_sort_key]
  end

  test "undrawn lottery results have nil lottery_sort_key" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Undrawn?", description: "", deadline: 1.minute.ago,
      subtype: "lottery",
    )
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Entry", decision_participant: participant)

    results = decision.results
    assert_nil results.first.lottery_sort_key
  end

  test "get_sorting_factor returns lottery_sort_key for drawn lottery" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Sorting factor?", description: "", deadline: 1.minute.ago,
      subtype: "lottery",
      lottery_beacon_round: 1,
      lottery_beacon_randomness: "beacon",
    )
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Alpha", decision_participant: participant)
    Option.create!(decision: decision, title: "Beta", decision_participant: participant)

    results = decision.results
    assert_equal "lottery_sort_key", results[0].get_sorting_factor(results[1])
  end

  test "get_sorting_factor returns random_id for undrawn lottery" do
    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Sorting factor?", description: "", deadline: 1.minute.ago,
      subtype: "lottery",
    )
    participant = DecisionParticipant.create!(decision: decision, user: @user)
    Option.create!(decision: decision, title: "Alpha", decision_participant: participant)
    Option.create!(decision: decision, title: "Beta", decision_participant: participant)

    results = decision.results
    assert_equal "random_id", results[0].get_sorting_factor(results[1])
  end
end
