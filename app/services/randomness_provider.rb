# typed: true
# frozen_string_literal: true

module RandomnessProvider
  extend T::Sig
  extend T::Helpers

  interface!

  sig { abstract.params(deadline: T.any(Time, ActiveSupport::TimeWithZone)).returns(Integer) }
  def round_for_timestamp(deadline); end

  sig { abstract.params(round_number: Integer).returns({ round: Integer, randomness: String }) }
  def fetch_round(round_number); end

  sig { abstract.params(round_number: Integer).returns(T.nilable(String)) }
  def verification_url(round_number); end

  # Returns structured data explaining how the round was derived from the deadline.
  # Views render this to let users verify the round wasn't chosen strategically.
  sig do
    abstract.params(deadline: T.any(Time, ActiveSupport::TimeWithZone), round_number: Integer)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def round_derivation(deadline, round_number); end

  class << self
    extend T::Sig

    sig { returns(RandomnessProvider) }
    def current
      provider_name = ENV.fetch("LOTTERY_RANDOMNESS_PROVIDER", "drand")
      case provider_name
      when "drand"
        RandomnessProvider::Drand.new
      when "test"
        RandomnessProvider::Test.new
      else
        raise "Unknown randomness provider: #{provider_name}"
      end
    end
  end
end
