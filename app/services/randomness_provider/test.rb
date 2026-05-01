# typed: true
# frozen_string_literal: true

module RandomnessProvider
  class Test
    extend T::Sig
    include RandomnessProvider

    DEFAULT_RANDOMNESS = "a]bc123def456789"

    sig { void }
    def initialize
      @randomness = T.let(DEFAULT_RANDOMNESS, String)
      @round = T.let(1, Integer)
    end

    sig { params(randomness: String).void }
    attr_writer :randomness

    sig { params(round: Integer).void }
    attr_writer :round

    sig { override.params(deadline: T.any(Time, ActiveSupport::TimeWithZone)).returns(Integer) }
    def round_for_timestamp(deadline) # rubocop:disable Lint/UnusedMethodArgument
      @round
    end

    sig { override.params(round_number: Integer).returns({ round: Integer, randomness: String }) }
    def fetch_round(round_number)
      { round: round_number, randomness: @randomness }
    end

    sig { override.params(round_number: Integer).returns(T.nilable(String)) }
    def verification_url(round_number) # rubocop:disable Lint/UnusedMethodArgument
      nil
    end

    sig do
      override.params(deadline: T.any(Time, ActiveSupport::TimeWithZone), round_number: Integer)
        .returns(T::Hash[Symbol, T.untyped])
    end
    def round_derivation(deadline, round_number) # rubocop:disable Lint/UnusedMethodArgument
      {
        description: "Test provider: round is a fixed configured value.",
        formula: nil,
        steps: [],
      }
    end
  end
end
