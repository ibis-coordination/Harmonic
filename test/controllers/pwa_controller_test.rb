# typed: false

require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  test "serves the service worker when the flag is enabled for the tenant" do
    @tenant.enable_feature_flag!(:service_worker)

    get "/service-worker.js"

    assert_response :success
    assert_match %r{text/javascript}, response.content_type
    assert_match(/self\.CACHE_VERSION = "\w+";/, response.body)
    assert_not_includes response.body, "unregister"
  end

  test "serves the unregister stub when the flag is disabled" do
    get "/service-worker.js"

    assert_response :success
    assert_match %r{text/javascript}, response.content_type
    assert_includes response.body, "unregister"
    assert_not_includes response.body, "CACHE_VERSION"
  end

  test "serves the unregister stub on an unknown subdomain" do
    host! "not-a-tenant.#{ENV.fetch("HOSTNAME", nil)}"

    get "/service-worker.js"

    assert_response :success
    assert_includes response.body, "unregister"
  end

  test "service worker does not require authentication" do
    @tenant.enable_feature_flag!(:service_worker)

    get "/service-worker.js"

    assert_response :success
  end

  test "service worker response is not HTTP-cacheable" do
    @tenant.enable_feature_flag!(:service_worker)

    get "/service-worker.js"

    assert_includes response.headers["Cache-Control"].to_s, "no-cache"
  end

  test "offline page renders without authentication" do
    get "/offline"

    assert_response :success
    assert_includes response.body.downcase, "offline"
  end
end
