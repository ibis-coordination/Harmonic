# typed: false

require "test_helper"

class HealthcheckControllerTest < ActionDispatch::IntegrationTest
  test "healthcheck returns ok when all services are healthy" do
    get "/healthcheck"

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "ok", json["status"]
    assert json["checks"]["database"], "Database check should pass"
    assert json["checks"]["redis"], "Redis check should pass"
  end

  test "healthcheck returns JSON format" do
    get "/healthcheck"

    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "healthcheck includes database check" do
    get "/healthcheck"

    json = JSON.parse(response.body)
    assert json.dig("checks", "database").is_a?(TrueClass) || json.dig("checks", "database").is_a?(FalseClass),
           "Database check should return boolean"
  end

  test "healthcheck includes redis check" do
    get "/healthcheck"

    json = JSON.parse(response.body)
    assert json.dig("checks", "redis").is_a?(TrueClass) || json.dig("checks", "redis").is_a?(FalseClass),
           "Redis check should return boolean"
  end

  test "healthcheck does not require authentication" do
    # Make request without any auth headers/cookies
    get "/healthcheck"

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "ok", json["status"]
  end

  test "healthcheck response includes checks hash" do
    get "/healthcheck"

    json = JSON.parse(response.body)
    assert json.key?("checks"), "Response should include checks hash"
    assert json["checks"].is_a?(Hash), "checks should be a hash"
  end

  test "healthcheck returns status as string" do
    get "/healthcheck"

    json = JSON.parse(response.body)
    assert json["status"].is_a?(String), "status should be a string"
    assert ["ok", "unhealthy"].include?(json["status"]), "status should be 'ok' or 'unhealthy'"
  end
end
