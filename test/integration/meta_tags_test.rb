require "test_helper"

# Verifies the discoverability surface:
#
#   - X-Robots-Tag: noindex, nofollow is set on every response EXCEPT
#     anon-viewer HTML responses to allows_anonymous actions on tenants in
#     ANON_READABLE_TENANT_SUBDOMAINS. Logged-in viewers, private tenants,
#     non-anon actions, and non-HTML formats (markdown, etc.) all get noindex.
#
#   - The Open Graph / Twitter Card block is emitted in the HTML body in
#     the SAME conditions where the noindex header is absent — single source
#     of truth via anon_readable_indexable_response?.
#
#   - Per-action @page_description / @page_title are populated correctly so
#     unfurlers (Slack/iMessage/Twitter) show the item-specific copy.
class MetaTagsTest < ActionDispatch::IntegrationTest
  PUBLIC_SUBDOMAIN = "metapublic".freeze
  PRIVATE_SUBDOMAIN = "metaprivate".freeze

  def setup
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = PUBLIC_SUBDOMAIN
    Tenant.reset_anon_readable_subdomains!

    @public_tenant = Tenant.create!(subdomain: PUBLIC_SUBDOMAIN, name: "Public")
    @private_tenant = Tenant.create!(subdomain: PRIVATE_SUBDOMAIN, name: "Private")

    @user = User.create!(email: "meta-owner@example.com", name: "Owner", user_type: "human")
    @public_tenant.add_user!(@user)
    @private_tenant.add_user!(@user)
    @public_tenant.create_main_collective!(created_by: @user)
    @private_tenant.create_main_collective!(created_by: @user)
    @main = @public_tenant.main_collective

    Tenant.scope_thread_to_tenant(subdomain: PUBLIC_SUBDOMAIN)
    Collective.set_thread_context(@main)

    @note = create_note(tenant: @public_tenant, collective: @main, created_by: @user,
                        title: "Public Note", text: "This is the first paragraph.\n\nA second one follows.")
    @untitled_note = create_note(tenant: @public_tenant, collective: @main, created_by: @user,
                                 title: nil, text: "Body without a title to fall back to.")
    @decision = create_decision(tenant: @public_tenant, collective: @main, created_by: @user,
                                question: "Should we?", description: "Some context here.")
    @commitment = create_commitment(tenant: @public_tenant, collective: @main, created_by: @user,
                                    title: "Run the event", description: "Details about the event.")
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    @test_ip = fresh_test_ip
    self.remote_addr = @test_ip
  end

  def teardown
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def host_for(subdomain)
    "#{subdomain}.#{ENV.fetch('HOSTNAME', nil)}"
  end

  # Mirrors canonical_base_url in ApplicationController. request.protocol is
  # set after a get/post, so call this only after the request runs.
  def canonical_url(subdomain, path)
    "#{request.protocol}#{host_for(subdomain)}#{path}"
  end

  # ---- X-Robots-Tag header ----

  test "anon GET /n/:id on anon-readable tenant does NOT set X-Robots-Tag" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @note.path
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"],
               "anon view of anon-readable HTML must be indexable (no X-Robots-Tag)"
  end

  test "anon GET /help/privacy on anon-readable tenant does NOT set X-Robots-Tag" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get "/help/privacy"
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
  end

  test "anon GET /u/:handle on anon-readable tenant does NOT set X-Robots-Tag" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @user.path
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
  end

  test "logged-in GET /n/:id on anon-readable tenant SETS X-Robots-Tag (per-user chrome shouldn't be indexed)" do
    sign_in_as(@user, tenant: @public_tenant)
    host! host_for(PUBLIC_SUBDOMAIN)
    get @note.path
    assert_response :success
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "anon GET /n/:id with markdown format SETS X-Robots-Tag (only HTML is the preview surface)" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @note.path, headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  # Curl's default Accept is `*/*` (Mime::ALL), and so is the wildcard tail of
  # every real browser's Accept header. Rails reports `request.format.html?`
  # as false for `*/*` even though the response IS HTML — same gotcha that
  # broke bypass condition 6 in the parent anon-read-access work. Indexable
  # must accept `*/*` the same way HTML is accepted.
  test "anon GET /n/:id with Accept: */* (curl default) emits the OG block and no noindex" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @note.path, headers: { "Accept" => "*/*" }
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
    assert_match %r{<meta property="og:title"}, response.body
  end

  test "anon GET /n/:id on PRIVATE tenant SETS X-Robots-Tag on the redirect response" do
    host! host_for(PRIVATE_SUBDOMAIN)
    get @note.path
    assert_response :redirect
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "anon GET / (a non-anon-allowed action) on anon-readable tenant SETS X-Robots-Tag" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get "/"
    # Root either redirects or renders; either way, since it's NOT allows_anonymous,
    # it must carry the noindex header.
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  # ---- OG / Twitter meta block ----

  test "anon GET /n/:id emits the OG block with the note title and a description excerpt" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @note.path
    assert_response :success
    assert_match %r{<meta property="og:title" content="Public Note"}, response.body
    assert_match %r{<meta property="og:description" content="[^"]*first paragraph}, response.body
    assert_match %r{<meta property="og:image" content="[^"]+/og-default\.png"}, response.body
    assert_match %r{<meta property="og:url" content="[^"]+#{Regexp.escape(@note.path)}"}, response.body
    assert_match %r{<meta property="og:site_name"}, response.body
    assert_match %r{<meta name="twitter:card" content="summary_large_image"}, response.body
    assert_match %r{<meta name="twitter:title" content="Public Note"}, response.body
    assert_match %r{<link rel="canonical" href="[^"]+#{Regexp.escape(@note.path)}"}, response.body
  end

  test "anon GET /n/:id with no title falls back to an excerpt for og:title" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @untitled_note.path
    assert_response :success
    assert_match %r{<meta property="og:title" content="[^"]*Body without}, response.body
  end

  # SEO de-duplication: query string variants of the same URL must declare the
  # SAME canonical URL, otherwise crawlers treat tracked links as separate pages.
  test "canonical URL strips the query string" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get "#{@note.path}?utm_source=email&utm_campaign=launch"
    assert_response :success
    expected_canonical = canonical_url(PUBLIC_SUBDOMAIN, @note.path)
    assert_match %r{<meta property="og:url" content="#{Regexp.escape(expected_canonical)}"}, response.body
    assert_match %r{<link rel="canonical" href="#{Regexp.escape(expected_canonical)}"}, response.body
  end

  # og:image must be on the canonical public hostname — not request.host_with_port,
  # which can leak an upstream port when behind a reverse proxy/CDN.
  test "og:image is built from the canonical hostname, no port" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @note.path
    assert_response :success
    expected_image = canonical_url(PUBLIC_SUBDOMAIN, "/og-default.png")
    assert_match %r{<meta property="og:image" content="#{Regexp.escape(expected_image)}"}, response.body
  end

  test "anon GET /d/:id emits og:title from the question" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @decision.path
    assert_response :success
    assert_match %r{<meta property="og:title" content="Should we\?"}, response.body
    assert_match %r{<meta property="og:description" content="[^"]*Some context}, response.body
  end

  test "anon GET /c/:id emits og:title from the title" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @commitment.path
    assert_response :success
    assert_match %r{<meta property="og:title" content="Run the event"}, response.body
    assert_match %r{<meta property="og:description" content="[^"]*Details about}, response.body
  end

  test "anon GET /u/:handle emits og:description with display name and tenant FQDN" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get @user.path
    assert_response :success
    assert_match %r{<meta property="og:title" content="Owner"}, response.body
    assert_match %r{<meta property="og:description" content="Owner on #{Regexp.escape(host_for(PUBLIC_SUBDOMAIN))}"}, response.body
  end

  test "anon GET /help/privacy emits og:title 'Help — Privacy'" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get "/help/privacy"
    assert_response :success
    assert_match %r{<meta property="og:title" content="Help — Privacy"}, response.body
    # First paragraph of privacy.md.erb mentions levels of visibility.
    assert_match %r{<meta property="og:description" content="[^"]*visibility}, response.body
  end

  test "anon GET /motto does NOT set X-Robots-Tag and emits the OG block" do
    host! host_for(PUBLIC_SUBDOMAIN)
    get "/motto"
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
    assert_match %r{<meta property="og:title" content="Do the right thing\. ❤️"}, response.body
    # First paragraph of motto/index.md.erb mentions "tuning fork".
    assert_match %r{<meta property="og:description" content="[^"]*tuning fork}, response.body
  end

  test "logged-in GET /n/:id does NOT emit OG block (per-user chrome shouldn't be indexed)" do
    sign_in_as(@user, tenant: @public_tenant)
    host! host_for(PUBLIC_SUBDOMAIN)
    get @note.path
    assert_response :success
    assert_no_match %r{<meta property="og:title"}, response.body
    assert_no_match %r{<meta property="og:image"}, response.body
    assert_no_match %r{<link rel="canonical"}, response.body
  end

  # ---- OG image asset exists ----

  test "public/og-default.png exists" do
    asset_path = Rails.root.join("public/og-default.png")
    assert File.exist?(asset_path), "expected #{asset_path} to exist"
  end
end
