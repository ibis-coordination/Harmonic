require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @user = @global_user
    @superagent = @global_superagent
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def auth_host
    "#{ENV['AUTH_SUBDOMAIN']}.#{ENV['HOSTNAME']}"
  end

  # === Login Flow Tests ===

  test "unauthenticated user on tenant subdomain is redirected to auth subdomain" do
    get "/login"
    assert_response :redirect
    assert_match /#{ENV['AUTH_SUBDOMAIN']}/, response.location
  end

  test "login page on auth subdomain shows login form" do
    host! auth_host
    # Set the redirect cookie to simulate coming from a tenant
    cookies[:redirect_to_subdomain] = @tenant.subdomain

    get "/login"
    assert_response :success
  end

  # === Logout Tests ===

  test "logout redirects to logout success" do
    delete "/logout"
    assert_response :redirect
    assert_match /logout-success/, response.location
  end

  test "logout success page renders for logged out user" do
    get "/logout-success"
    assert_response :success
  end

  # === Internal Callback Tests ===

  test "internal callback without token redirects to login" do
    get "/login/callback"
    assert_response :redirect
    assert_match /login/, response.location
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
    assert_match /login/, response.location
  end

  # === Return Endpoint Tests ===

  test "return endpoint without user redirects to login" do
    host! auth_host

    get "/login/return"
    assert_response :redirect
    assert_match /login/, response.location
  end

  private

  def generate_test_token(tenant, user)
    # Generate an encrypted token similar to what SessionsController does
    # This mirrors the encrypt_token method in ApplicationController
    key = Rails.application.secret_key_base[0..31]
    crypt = ActiveSupport::MessageEncryptor.new(key)
    timestamp = Time.current.to_i
    crypt.encrypt_and_sign("#{tenant.id}:#{user.id}:#{timestamp}")
  end
end
