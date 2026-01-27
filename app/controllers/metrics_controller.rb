# typed: false
# frozen_string_literal: true

# MetricsController exposes Prometheus-format metrics for scraping
# Protected by a simple token authentication
# Inherits from ActionController::Base (not ApplicationController) to bypass tenant/user context
class MetricsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  before_action :authenticate_metrics_token

  def show
    # Skip standard application callbacks for metrics endpoint
    exporter = Yabeda::Prometheus::Exporter.new
    render plain: exporter.call({})&.last&.first || "", content_type: "text/plain"
  end

  private

  def authenticate_metrics_token
    expected_token = ENV.fetch("METRICS_AUTH_TOKEN", nil)

    # Require token in production
    if Rails.env.production? && expected_token.blank?
      render plain: "Metrics endpoint not configured", status: :service_unavailable
      return
    end

    # Skip auth if no token configured (non-production)
    return if expected_token.blank?

    provided_token = request.headers["Authorization"]&.delete_prefix("Bearer ")

    return if ActiveSupport::SecurityUtils.secure_compare(provided_token.to_s, expected_token)

    render plain: "Unauthorized", status: :unauthorized
  end
end
