require "test_helper"

# Verifies /manifest.json serves the PWA web app manifest so the app can be
# installed to a phone's home screen. Served per-subdomain so each tenant
# installs as a separate home-screen entry, scoped to its own origin.
class PwaManifestTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  test "GET /manifest.json returns valid JSON with the required fields" do
    get "/manifest.json"
    assert_response :success
    assert_equal "application/json", response.media_type

    json = response.parsed_body
    assert_equal "Harmonic", json["name"]
    assert_equal "standalone", json["display"]
    assert_equal "/", json["start_url"]
    assert_equal "/", json["scope"]
    assert json["icons"].is_a?(Array) && json["icons"].any?, "manifest must declare at least one icon"
  end

  test "layout head links to the manifest and declares mobile meta tags" do
    get "/login"
    follow_redirect! if response.redirect?
    assert_response :success

    assert_match(%r{<link rel="manifest" href="/manifest.json">}, response.body)
    assert_match(/<meta name="theme-color"/, response.body)
    assert_match(/<link rel="apple-touch-icon"/, response.body)
    assert_match(/<meta name="apple-mobile-web-app-title" content="Harmonic">/, response.body)
  end
end
