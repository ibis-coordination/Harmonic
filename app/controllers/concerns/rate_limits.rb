# typed: false

# Per-user (and arbitrary compound-key) rate limiting for controller actions.
#
# Rack::Attack handles IP-keyed and pre-auth throttles. This concern handles
# the cases that need post-auth context — current_user, target item, target
# agent — that aren't available to rack-attack's middleware. Counters live
# in Redis (via Sidekiq's connection pool) so they survive across processes.
#
# Usage:
#   include RateLimits
#
#   def create
#     enforce_rate_limit!(scope: "comments", key: [current_user.id, parent.id],
#                         limit: 5, period: 1.minute)
#     # ...
#   rescue RateLimits::Exceeded
#     # render or redirect with a friendly error
#   end
module RateLimits
  extend ActiveSupport::Concern

  class Exceeded < StandardError
    attr_reader :scope, :limit, :period

    def initialize(scope:, limit:, period:)
      @scope = scope
      @limit = limit
      @period = period
      super("Rate limit exceeded for #{scope} (#{limit} per #{period.inspect})")
    end
  end

  # Fixed-window counter. Returns the count after increment; raises Exceeded
  # if the count exceeds `limit`.
  def enforce_rate_limit!(scope:, key:, limit:, period:)
    redis_key = ["rate_limit", scope, *Array(key)].join(":")

    count = Sidekiq.redis do |conn|
      c = conn.incr(redis_key)
      conn.expire(redis_key, period.to_i) if c == 1
      c
    end

    raise Exceeded.new(scope: scope, limit: limit, period: period) if count > limit

    count
  end
end
