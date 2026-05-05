# typed: false

require "test_helper"

class LotteryServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
  end

  def create_lottery_decision(deadline: 1.minute.ago)
    Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Lottery test?", description: "",
      deadline: deadline,
      subtype: "lottery",
    )
  end

  def add_option(decision, title)
    participant = DecisionParticipant.find_or_create_by!(decision: decision, user: @user)
    Option.create!(decision: decision, title: title, decision_participant: participant)
  end

  # === draw! tests ===

  test "draw! stores beacon data on decision" do
    provider = RandomnessProvider::Test.new
    provider.randomness = "test_random_hex"
    provider.round = 42
    service = LotteryService.new(provider: provider)

    decision = create_lottery_decision
    service.draw!(decision)

    decision.reload
    assert_equal 42, decision.lottery_beacon_round
    assert_equal "test_random_hex", decision.lottery_beacon_randomness
  end

  test "draw! works for vote decisions" do
    provider = RandomnessProvider::Test.new
    provider.randomness = "vote_random_hex"
    provider.round = 99
    service = LotteryService.new(provider: provider)

    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Vote?", description: "", deadline: 1.minute.ago,
      subtype: "vote",
    )

    service.draw!(decision)
    decision.reload
    assert_equal 99, decision.lottery_beacon_round
    assert_equal "vote_random_hex", decision.lottery_beacon_randomness
  end

  test "draw! raises if decision is executive" do
    provider = RandomnessProvider::Test.new
    service = LotteryService.new(provider: provider)

    decision = Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Executive?", description: "", deadline: 1.minute.ago,
      subtype: "executive",
      decision_maker: @user,
    )

    assert_raises(RuntimeError, "Decision must be a lottery or vote") do
      service.draw!(decision)
    end
  end

  test "draw! raises if already drawn" do
    provider = RandomnessProvider::Test.new
    service = LotteryService.new(provider: provider)

    decision = create_lottery_decision
    decision.update!(lottery_beacon_round: 1, lottery_beacon_randomness: "existing")

    assert_raises(RuntimeError, "Beacon has already been drawn") do
      service.draw!(decision)
    end
  end

  # === verification_url tests ===

  test "verification_url returns nil for Test provider" do
    provider = RandomnessProvider::Test.new
    service = LotteryService.new(provider: provider)
    decision = create_lottery_decision
    decision.update!(lottery_beacon_round: 42, lottery_beacon_randomness: "test")

    assert_nil service.verification_url(decision)
  end

  test "verification_url returns drand URL for Drand provider" do
    provider = RandomnessProvider::Drand.new
    service = LotteryService.new(provider: provider)
    decision = create_lottery_decision
    decision.update!(lottery_beacon_round: 12345, lottery_beacon_randomness: "test")

    url = service.verification_url(decision)
    assert_includes url, "12345"
    assert_includes url, "api.drand.sh"
  end
end
