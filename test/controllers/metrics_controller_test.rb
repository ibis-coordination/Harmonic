# typed: false
# frozen_string_literal: true

require "test_helper"

class MetricsControllerTest < ActionDispatch::IntegrationTest
  test "renders Prometheus text format" do
    get "/metrics"
    assert_response :success
    assert_equal "text/plain", response.media_type
    # Prometheus text format is comment lines (# HELP / # TYPE) and samples;
    # with no auth token configured outside production, the endpoint is open.
    assert_match(/\A(#|[a-zA-Z_:]|\z)/, response.body)
  end

  test "rejects a wrong token when one is configured" do
    ENV["METRICS_AUTH_TOKEN"] = "expected-token"
    get "/metrics", headers: { "Authorization" => "Bearer wrong-token" }
    assert_response :unauthorized
  ensure
    ENV.delete("METRICS_AUTH_TOKEN")
  end

  test "accepts the configured token" do
    ENV["METRICS_AUTH_TOKEN"] = "expected-token"
    get "/metrics", headers: { "Authorization" => "Bearer expected-token" }
    assert_response :success
  ensure
    ENV.delete("METRICS_AUTH_TOKEN")
  end
end
