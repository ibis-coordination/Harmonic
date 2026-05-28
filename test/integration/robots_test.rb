require "test_helper"

# Verifies /robots.txt serves per-tenant content:
#   - Anon-readable tenants get an Allow-list of the four anon URL shapes
#     plus a Sitemap: line.
#   - Private tenants and unknown subdomains get a strict Disallow: / body.
#   - The endpoint itself is cacheable (max-age=3600, private) and
#     X-Robots-Tag: noindex so robots.txt doesn't show up as a search result.
class RobotsTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "robotspublic".freeze
  PRIVATE_SUBDOMAIN = "robotsprivate".freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!

    @public_tenant = Tenant.find_or_create_by!(subdomain: PUBLIC_SUBDOMAIN) { |t| t.name = "Public" }
    @private_tenant = Tenant.find_or_create_by!(subdomain: PRIVATE_SUBDOMAIN) { |t| t.name = "Private" }
  end

  def teardown
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
  end

  # ---- Anon-readable tenant ----

  test "GET /robots.txt on anon-readable tenant returns 200 text/plain with Allow rules" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/robots.txt"
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_match(/User-agent: \*/, response.body)
    assert_match(%r{Disallow: /}, response.body)
    assert_match(%r{Allow: /n/}, response.body)
    assert_match(%r{Allow: /d/}, response.body)
    assert_match(%r{Allow: /c/}, response.body)
    assert_match(%r{Allow: /u/}, response.body)
    assert_match(%r{Allow: /help}, response.body)
    assert_match(%r{Allow: /motto}, response.body)
  end

  # No sitemap.xml in this feature — discoverability of Harmonic content via
  # search engines is not a current product goal. If that changes, the
  # Sitemap: directive comes back in tandem with a real sitemap endpoint.
  test "GET /robots.txt on anon-readable tenant does NOT advertise a sitemap" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/robots.txt"
    assert_no_match(/Sitemap:/, response.body)
  end

  # ---- Private tenant ----

  test "GET /robots.txt on private tenant returns exactly Disallow: /" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/robots.txt"
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal "User-agent: *\nDisallow: /\n", response.body
  end

  test "GET /robots.txt on private tenant does NOT advertise a sitemap" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/robots.txt"
    assert_no_match(/Sitemap:/, response.body)
    assert_no_match(%r{Allow:}, response.body)
  end

  # ---- Unknown subdomain ----

  test "GET /robots.txt on unknown subdomain falls back to private rules" do
    host! "doesnotexist#{SecureRandom.hex(4)}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/robots.txt"
    assert_response :success
    assert_equal "User-agent: *\nDisallow: /\n", response.body
  end

  # ---- Caching headers ----

  test "GET /robots.txt sets Cache-Control: max-age=3600, private" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/robots.txt"
    cache_control = response.headers["Cache-Control"].to_s
    assert_match(/max-age=3600/, cache_control)
    assert_match(/private/, cache_control)
  end

  test "GET /robots.txt sets X-Robots-Tag: noindex on the robots.txt response itself" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/robots.txt"
    assert_match(/noindex/, response.headers["X-Robots-Tag"].to_s)
  end

  # ---- HEAD requests (crawler probes) ----

  test "HEAD /robots.txt on anon-readable tenant returns 200 with the right headers" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    head "/robots.txt"
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_match(/noindex/, response.headers["X-Robots-Tag"].to_s)
  end

  test "HEAD /robots.txt on private tenant returns 200" do
    host! "#{PRIVATE_SUBDOMAIN}.#{ENV.fetch('HOSTNAME', nil)}"
    head "/robots.txt"
    assert_response :success
  end
end
