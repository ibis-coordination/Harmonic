# typed: false

require "test_helper"

class RandomnessProviderTest < ActiveSupport::TestCase
  # === Test Provider ===

  test "Test provider returns configured values" do
    provider = RandomnessProvider::Test.new
    provider.randomness = "custom_hex"
    provider.round = 99

    result = provider.fetch_round(99)
    assert_equal 99, result[:round]
    assert_equal "custom_hex", result[:randomness]
  end

  test "Test provider round_for_timestamp returns configured round" do
    provider = RandomnessProvider::Test.new
    provider.round = 42

    assert_equal 42, provider.round_for_timestamp(Time.now)
  end

  test "Test provider verification_url returns nil" do
    provider = RandomnessProvider::Test.new
    assert_nil provider.verification_url(1)
  end

  # === Drand Provider ===

  test "Drand round_for_timestamp computes correct round" do
    provider = RandomnessProvider::Drand.new

    # Returns the first round AFTER the deadline (not yet published at deadline).
    # Round 1 is at genesis, round 2 at genesis+3, round 3 at genesis+6, etc.
    genesis = Time.at(RandomnessProvider::Drand::GENESIS_TIME)

    # At genesis: round 1 is already published, so return round 2
    assert_equal 2, provider.round_for_timestamp(genesis)

    # 1 second after genesis: round 1 published at genesis, round 2 at genesis+3 — return 2
    assert_equal 2, provider.round_for_timestamp(genesis + 1)

    # 3 seconds after genesis: round 2 published at genesis+3, so return round 3
    assert_equal 3, provider.round_for_timestamp(genesis + 3)

    # 4 seconds after genesis: round 2 published at genesis+3 (already known), return round 3
    assert_equal 3, provider.round_for_timestamp(genesis + 4)

    # 6 seconds after genesis: round 3 published at genesis+6, so return round 4
    assert_equal 4, provider.round_for_timestamp(genesis + 6)
  end

  test "Drand round_for_timestamp returns 2 for pre-genesis time" do
    provider = RandomnessProvider::Drand.new
    assert_equal 2, provider.round_for_timestamp(Time.at(0))
  end

  test "Drand verification_url includes chain hash and round" do
    provider = RandomnessProvider::Drand.new
    url = provider.verification_url(12345)

    assert_includes url, RandomnessProvider::Drand::CHAIN_HASH
    assert_includes url, "12345"
    assert_includes url, "api.drand.sh"
  end

  # === Provider Factory ===

  test "current returns Drand provider by default" do
    # Default is drand when LOTTERY_RANDOMNESS_PROVIDER is not set
    provider = RandomnessProvider.current
    assert_instance_of RandomnessProvider::Drand, provider
  end

  test "current returns Test provider when configured" do
    original = ENV["LOTTERY_RANDOMNESS_PROVIDER"]
    ENV["LOTTERY_RANDOMNESS_PROVIDER"] = "test"
    begin
      provider = RandomnessProvider.current
      assert_instance_of RandomnessProvider::Test, provider
    ensure
      if original
        ENV["LOTTERY_RANDOMNESS_PROVIDER"] = original
      else
        ENV.delete("LOTTERY_RANDOMNESS_PROVIDER")
      end
    end
  end

  test "current raises for unknown provider" do
    original = ENV["LOTTERY_RANDOMNESS_PROVIDER"]
    ENV["LOTTERY_RANDOMNESS_PROVIDER"] = "unknown"
    begin
      assert_raises(RuntimeError) do
        RandomnessProvider.current
      end
    ensure
      if original
        ENV["LOTTERY_RANDOMNESS_PROVIDER"] = original
      else
        ENV.delete("LOTTERY_RANDOMNESS_PROVIDER")
      end
    end
  end
end
