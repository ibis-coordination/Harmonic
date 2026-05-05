# typed: true
# frozen_string_literal: true

class LotteryService
  extend T::Sig

  sig { params(provider: RandomnessProvider).void }
  def initialize(provider: RandomnessProvider.current)
    @provider = T.let(provider, RandomnessProvider)
  end

  sig { params(decision: Decision).void }
  def draw!(decision)
    raise "Decision must be a lottery or vote" unless decision.is_lottery? || decision.is_vote?
    raise "Beacon has already been drawn" if decision.beacon_drawn?

    round_number = @provider.round_for_timestamp(T.must(decision.deadline))
    result = @provider.fetch_round(round_number)

    decision.update!(
      lottery_beacon_round: result[:round],
      lottery_beacon_randomness: result[:randomness]
    )
  end

  sig { params(decision: Decision).returns(T.nilable(String)) }
  def verification_url(decision)
    return nil if decision.lottery_beacon_round.blank?

    @provider.verification_url(T.must(decision.lottery_beacon_round))
  end
end
