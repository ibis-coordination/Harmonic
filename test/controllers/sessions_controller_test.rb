require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @user = @global_user
    @superagent = @global_superagent
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def auth_host
    "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Login Flow Tests ===

  test "unauthenticated user on tenant subdomain is redirected to auth subdomain" do
    get "/login"
    assert_response :redirect
    assert_match(/#{ENV.fetch("AUTH_SUBDOMAIN", nil)}/, response.location)
  end

  test "redirect to auth subdomain sets redirect_to_subdomain cookie" do
    get "/login"
    assert_response :redirect
    # Verify the cookie was set with the tenant's subdomain
    assert_equal @tenant.subdomain, cookies[:redirect_to_subdomain],
                 "Cookie should be set to the originating tenant subdomain"
  end

  test "login page on auth subdomain shows login form" do
    host! auth_host
    # Set the redirect cookie to simulate coming from a tenant
    cookies[:redirect_to_subdomain] = @tenant.subdomain

    get "/login"
    assert_response :success
  end

  # === Non-Primary Tenant Login Flow Tests ===
  #
  # NOTE: These tests verify the cookie-based subdomain tracking logic, but they
  # pass even when the bug exists in real browsers. This is because Rails integration
  # tests simulate cookies in memory, which works perfectly across "host!" switches.
  #
  # The actual bug manifests in real browsers where the cookie set with
  # `domain: ".harmonic.local"` may not be properly shared across subdomains due to:
  # - Browser security policies for .local domains
  # - Cookie timing/persistence issues during redirects
  #
  # See e2e/tests/auth/non-primary-tenant-login.spec.ts for E2E tests that can
  # reproduce the bug in a real browser environment.

  test "non-primary tenant login flow preserves subdomain through redirect" do
    # Create a non-primary tenant with required main superagent
    secondary_tenant = create_tenant(subdomain: "secondary", name: "Secondary Tenant")
    secondary_user = create_user(email: "secondary@example.com", name: "Secondary User")
    secondary_tenant.add_user!(secondary_user)
    secondary_tenant.create_main_superagent!(created_by: secondary_user)

    # Step 1: User visits the secondary tenant's login page
    host! "#{secondary_tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    get "/login"

    # Should redirect to auth subdomain
    assert_response :redirect
    assert_match(/#{ENV.fetch("AUTH_SUBDOMAIN", nil)}/, response.location)

    # The cookie should be set to the secondary tenant's subdomain
    assert_equal secondary_tenant.subdomain, cookies[:redirect_to_subdomain],
                 "Cookie should be set to 'secondary', not the primary subdomain"

    # Step 2: Follow redirect to auth subdomain
    host! auth_host
    get "/login"

    assert_response :success

    # Verify the login page displays the correct tenant subdomain
    assert_select "code", text: /#{secondary_tenant.subdomain}\.#{ENV.fetch("HOSTNAME", nil)}/,
                          message: "Login page should display 'secondary.harmonic.local', not 'app.harmonic.local'"
  end

  test "login page on auth subdomain shows correct tenant when cookie is preserved" do
    # Create a non-primary tenant
    secondary_tenant = create_tenant(subdomain: "second", name: "Second Tenant")

    # Simulate the cookie being properly set (this is what SHOULD happen)
    host! auth_host
    cookies[:redirect_to_subdomain] = secondary_tenant.subdomain

    get "/login"

    assert_response :success
    # The @original_tenant should be the secondary tenant, not the primary
    assert_select "code", text: /#{secondary_tenant.subdomain}\.#{ENV.fetch("HOSTNAME", nil)}/,
                          message: "Login page should display the secondary tenant subdomain"
  end

  test "login page defaults to primary subdomain when cookie is missing" do
    # This documents the CURRENT (buggy) behavior
    # When no cookie is set, it defaults to PRIMARY_SUBDOMAIN
    # First, ensure the primary tenant exists
    primary_tenant = Tenant.find_by(subdomain: ENV.fetch("PRIMARY_SUBDOMAIN", nil))
    unless primary_tenant
      primary_tenant = create_tenant(subdomain: ENV.fetch("PRIMARY_SUBDOMAIN", nil), name: "Primary Tenant")
      primary_user = create_user(email: "primary@example.com", name: "Primary User")
      primary_tenant.add_user!(primary_user)
      primary_tenant.create_main_superagent!(created_by: primary_user)
    end

    host! auth_host
    # Explicitly ensure no cookie is set
    cookies.delete(:redirect_to_subdomain)

    get "/login"

    assert_response :success
    # Currently defaults to primary subdomain
    assert_select "code", text: /#{ENV.fetch("PRIMARY_SUBDOMAIN", nil)}\.#{ENV.fetch("HOSTNAME", nil)}/
  end

  # === Logout Tests ===

  test "logout redirects to logout success" do
    delete "/logout"
    assert_response :redirect
    assert_match(/logout-success/, response.location)
  end

  test "logout logs security audit event for authenticated user" do
    sign_in_as(@user, tenant: @tenant)
    test_email = @user.email

    delete "/logout"

    assert_response :redirect

    # Verify logout was logged by parsing JSON entries
    log_file = Rails.root.join("log/security_audit.log")
    if File.exist?(log_file)
      entries = File.readlines(log_file).map { |line| JSON.parse(line) rescue nil }.compact
      matching_entry = entries.find do |e|
        e["event"] == "logout" && e["email"] == test_email
      end
      assert matching_entry, "Expected to find logout event for #{test_email}"
    end
  end

  test "logout success page renders for logged out user" do
    get "/logout-success"
    assert_response :success
  end

  # === Internal Callback Tests ===

  test "internal callback without token redirects to login" do
    get "/login/callback"
    assert_response :redirect
    assert_match(/login/, response.location)
  end

  test "internal callback with valid token processes login" do
    token = generate_test_token(@tenant, @user)
    cookies[:token] = token

    get "/login/callback"
    # Should redirect to root or resource after successful login
    assert_response :redirect
  end

  # === OAuth Failure Tests ===

  test "oauth failure redirects to login with error message" do
    host! auth_host

    get "/auth/failure", params: { message: "access_denied" }
    assert_response :redirect
    assert_match(/login/, response.location)
  end

  test "oauth failure shows friendly message for invalid credentials" do
    host! auth_host

    get "/auth/failure", params: { message: "invalid_credentials" }
    assert_response :redirect
    assert_equal "Invalid email or password. Please try again.", flash[:alert]
  end

  test "oauth failure shows friendly message for csrf detected" do
    host! auth_host

    get "/auth/failure", params: { message: "csrf_detected" }
    assert_response :redirect
    assert_equal "Your login session expired. Please try again.", flash[:alert]
  end

  test "oauth failure shows generic message for unknown failures" do
    host! auth_host

    get "/auth/failure", params: { message: "some_unknown_error" }
    assert_response :redirect
    assert_equal "We couldn't complete your login. Please try again.", flash[:alert]
  end

  test "oauth failure logs security audit event" do
    host! auth_host
    test_reason = "access_denied_#{SecureRandom.hex(4)}"

    get "/auth/failure", params: { message: test_reason, email: "attacker@example.com" }

    assert_response :redirect

    # Verify login failure was logged by parsing JSON entries
    log_file = Rails.root.join("log/security_audit.log")
    if File.exist?(log_file)
      entries = File.readlines(log_file).map { |line| JSON.parse(line) rescue nil }.compact
      matching_entry = entries.find do |e|
        e["event"] == "login_failure" && e["reason"] == test_reason
      end
      assert matching_entry, "Expected to find login_failure event with reason #{test_reason}"
    end
  end

  # === Return Endpoint Tests ===

  test "return endpoint without user redirects to login" do
    host! auth_host

    get "/login/return"
    assert_response :redirect
    assert_match(/login/, response.location)
  end

  private

  def generate_test_token(tenant, user)
    # Generate an encrypted token similar to what SessionsController does
    # This mirrors the encryptor method in ApplicationController with key derivation
    derived_key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                    .generate_key("cross_subdomain_token", 32)
    crypt = ActiveSupport::MessageEncryptor.new(derived_key)
    timestamp = Time.current.to_i
    crypt.encrypt_and_sign("#{tenant.id}:#{user.id}:#{timestamp}")
  end
end
