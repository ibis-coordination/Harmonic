# typed: false
require "test_helper"

# Tests for the RateLimits controller concern.
#
# Uses a stub host class so the helper can be exercised in isolation, separate
# from controller-level integration that lives in the controller test suites.
class RateLimitsTest < ActiveSupport::TestCase
  class StubHost
    include RateLimits
  end

  setup do
    @host = StubHost.new
    @scope = "rate_limits_test_#{SecureRandom.hex(4)}"
  end

  teardown do
    Sidekiq.redis do |conn|
      keys = conn.keys("rate_limit:#{@scope}:*")
      conn.del(*keys) if keys.any?
    end
  end

  test "increments the Redis counter and returns the new count" do
    assert_equal 1, @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 5, period: 60.seconds)
    assert_equal 2, @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 5, period: 60.seconds)
  end

  test "allows requests up to and including the limit" do
    5.times do |i|
      assert_equal i + 1, @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 5, period: 60.seconds)
    end
  end

  test "raises Exceeded once the limit is crossed" do
    5.times { @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 5, period: 60.seconds) }

    assert_raises(RateLimits::Exceeded) do
      @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 5, period: 60.seconds)
    end
  end

  test "different keys are tracked independently" do
    5.times { @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 5, period: 60.seconds) }

    assert_equal 1, @host.enforce_rate_limit!(scope: @scope, key: "user_2", limit: 5, period: 60.seconds)
  end

  test "compound keys produce independent namespaces" do
    @host.enforce_rate_limit!(scope: @scope, key: ["user_1", "item_42"], limit: 5, period: 60.seconds)

    fresh_count = @host.enforce_rate_limit!(scope: @scope, key: ["user_1", "item_99"], limit: 5, period: 60.seconds)
    assert_equal 1, fresh_count
  end

  test "Exceeded exception carries scope and limit for handlers" do
    @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 1, period: 60.seconds)

    error = assert_raises(RateLimits::Exceeded) do
      @host.enforce_rate_limit!(scope: @scope, key: "user_1", limit: 1, period: 60.seconds)
    end
    assert_equal @scope, error.scope
    assert_equal 1, error.limit
  end

  test "the TTL is set on every increment, not just the first" do
    # Regression test: previously EXPIRE was only called on the first
    # increment, so a key whose EXPIRE failed (or got missed via a transient
    # Redis hiccup) could persist forever and permanently block the bucket.
    # Now EXPIRE is called every time.
    redis_key = "rate_limit:#{@scope}:ttl_check"

    @host.enforce_rate_limit!(scope: @scope, key: "ttl_check", limit: 5, period: 60.seconds)

    # Simulate the broken state: a key with a count but no TTL.
    Sidekiq.redis { |conn| conn.persist(redis_key) }
    Sidekiq.redis do |conn|
      assert_equal(-1, conn.ttl(redis_key), "precondition: key should have no TTL after persist")
    end

    # The next increment should reinstate a TTL.
    @host.enforce_rate_limit!(scope: @scope, key: "ttl_check", limit: 5, period: 60.seconds)
    Sidekiq.redis do |conn|
      ttl = conn.ttl(redis_key)
      assert ttl.positive?, "expected a positive TTL after the second increment, got #{ttl}"
      assert ttl <= 60, "expected TTL <= configured period, got #{ttl}"
    end
  end
end
