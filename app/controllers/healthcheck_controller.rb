# typed: true

# Health check endpoint for load balancers and monitoring.
# Does not inherit from ApplicationController to avoid authentication and tenant scoping.
class HealthcheckController < ActionController::Base
  def healthcheck
    checks = {
      database: check_database,
      redis: check_redis,
    }

    status = checks.values.all? ? :ok : :service_unavailable
    render json: { status: status == :ok ? "ok" : "unhealthy", checks: checks }, status: status
  end

  private

  def check_database
    ActiveRecord::Base.connection.execute("SELECT 1")
    true
  rescue StandardError => e
    Rails.logger.error("Healthcheck database error: #{e.message}")
    false
  end

  def check_redis
    redis = Redis.new(url: ENV["REDIS_URL"])
    redis.ping == "PONG"
  rescue StandardError => e
    Rails.logger.error("Healthcheck Redis error: #{e.message}")
    false
  ensure
    redis&.close
  end
end
