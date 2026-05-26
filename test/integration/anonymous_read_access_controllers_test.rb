require "test_helper"

# Phase 2 verification: the allows_anonymous declarations live in the real
# controller files (NotesController, DecisionsController, CommitmentsController,
# HelpController). Phase 1's bypass test temporarily declared these inline;
# Phase 2 makes them permanent.
#
# Also verifies the per-action Cache-Control headers (Section D) and the
# per-IP rate limit (Section I).
class AnonymousReadAccessControllersTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "anonctrlpublic".freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!

    @tenant = Tenant.create!(subdomain: PUBLIC_SUBDOMAIN, name: "Public")
    @user = User.create!(email: "ctrlowner@example.com", name: "Owner", user_type: "human")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
    @main = @tenant.main_collective

    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@main)
    @note = create_note(tenant: @tenant, collective: @main, created_by: @user)
    @decision = create_decision(tenant: @tenant, collective: @main, created_by: @user)
    @commitment = create_commitment(tenant: @tenant, collective: @main, created_by: @user)
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    # Per-test unique IP so the per-IP rate-limit counter in Redis can't
    # collide across parallel workers (which all share Redis DB 15).
    @test_ip = unique_ip
  end

  def teardown
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  # ---- allows_anonymous declarations live in the real controllers ----

  test "NotesController declares allows_anonymous :show" do
    assert NotesController.allows_anonymous?(:show),
           "Phase 2 should declare allows_anonymous :show on NotesController"
  end

  test "DecisionsController declares allows_anonymous :show" do
    assert DecisionsController.allows_anonymous?(:show)
  end

  test "CommitmentsController declares allows_anonymous :show" do
    assert CommitmentsController.allows_anonymous?(:show)
  end

  test "HelpController declares allows_anonymous for index and every topic" do
    assert HelpController.allows_anonymous?(:index), "/help index"
    HelpController::TOPICS.each do |topic|
      assert HelpController.allows_anonymous?(topic.to_sym), "/help/#{topic}"
    end
  end

  test "subclasses of NotesController do NOT inherit allows_anonymous" do
    sub = Class.new(NotesController)
    assert_not sub.allows_anonymous?(:show),
               "subclass must not inherit — otherwise Api::V1::NotesController would silently allow anon"
  end

  # ---- anon GET succeeds without Phase-1-style test wiring ----

  test "anon GET /n/:id returns 200 with no test-side allows_anonymous declaration" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @note.path
    assert_response :success
  end

  test "anon GET /d/:id returns 200 with no test-side allows_anonymous declaration" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @decision.path
    assert_response :success
  end

  test "anon GET /c/:id returns 200 with no test-side allows_anonymous declaration" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @commitment.path
    assert_response :success
  end

  test "anon GET /help returns 200 with no test-side allows_anonymous declaration" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help"
    assert_response :success
  end

  test "anon GET /help/privacy returns 200" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help/privacy"
    assert_response :success
  end

  # ---- Feature-gated help topic 404s when flag off ----

  test "anon GET /help/api 404s when api feature flag is off" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help/api"
    assert_response :not_found
  end

  # ---- HEAD requests (Section B condition 4) ----
  #
  # The bypass predicate explicitly allows `request.head?`. Test the most
  # likely HEAD caller (monitors, health checks, link previews).

  test "anon HEAD /n/:id on PUBLIC main collective returns 200 with no-cache headers" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    head @note.path
    assert_response :success
    assert_match(/no-store/, response.headers["Cache-Control"],
                 "HEAD must set the same no-cache headers as GET — monitors/preview-fetchers " \
                 "shouldn't be able to populate caches with a HEAD probe")
  end

  test "anon HEAD /help/privacy on PUBLIC tenant returns 200" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    head "/help/privacy"
    assert_response :success
  end

  # ---- Cache-Control headers (Section D) ----

  test "anon GET /n/:id sets Cache-Control: private, no-store" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @note.path
    assert_response :success
    assert_match(/private/, response.headers["Cache-Control"])
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "anon GET /d/:id sets the same anti-cache headers" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @decision.path
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "anon GET /c/:id sets the same anti-cache headers" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @commitment.path
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "anon GET /help sets the same anti-cache headers (consistency)" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/help"
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "LOGGED-IN GET /n/:id also sets anti-cache headers (prevents cross-audience CDN reuse)" do
    sign_in_as(@user, tenant: @tenant)
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    get @note.path
    assert_response :success
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  # ---- Per-IP rate limit (Section I) ----
  #
  # All tests use @test_ip (set in setup) as REMOTE_ADDR so the per-IP
  # rate-limit counter is isolated per test and can't collide across parallel
  # workers sharing Redis DB 15.

  test "anon GET /n/:id 60th request OK, 61st returns 429 and logs to SecurityAuditLog" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    60.times { get @note.path, env: { "REMOTE_ADDR" => @test_ip } }
    assert_response :success

    recorded = []
    SecurityAuditLog.stub(:log_rate_limited, ->(**kw) { recorded << kw }) do
      get @note.path, env: { "REMOTE_ADDR" => @test_ip }
    end
    assert_response :too_many_requests
    assert response.headers["Retry-After"].present?, "expected Retry-After header on 429"
    assert_equal 1, recorded.size, "expected one SecurityAuditLog.log_rate_limited call"
    assert_equal({ ip: @test_ip, matched: "anon_read", request_path: @note.path }, recorded.first)
  end

  test "logged-in GET /n/:id is NOT subject to the anonymous per-IP rate limit" do
    sign_in_as(@user, tenant: @tenant)
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    61.times { get @note.path, env: { "REMOTE_ADDR" => @test_ip } }
    assert_response :success
  end

  test "help is NOT rate-limited (explicit plan decision: small static surface)" do
    host! "#{PUBLIC_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    65.times { get "/help/privacy", env: { "REMOTE_ADDR" => @test_ip } }
    assert_response :success
  end

  private

  def unique_ip
    # 10.0.0.0/8 is private-use; randomize so parallel workers don't collide
    # on the Redis counter.
    "10.#{rand(256)}.#{rand(256)}.#{rand(1..254)}"
  end
end
