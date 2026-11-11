require "test_helper"

# OmniAuth builds the callback URL it sends to the provider from the
# request's host (Host or X-Forwarded-Host). OAuth only ever runs on the
# auth host, so OmniAuth.config.allowed_hosts names that one host and every
# other host fails the request phase with invalid_host.
class OmniAuthAllowedHostsTest < ActionDispatch::IntegrationTest
  def auth_host
    "#{ENV.fetch("AUTH_SUBDOMAIN")}.#{ENV.fetch("HOSTNAME")}"
  end

  test "allowed hosts are the auth subdomain of HOSTNAME" do
    hosts = OmniAuthAllowedHosts.for_env({ "HOSTNAME" => "harmonic.social", "AUTH_SUBDOMAIN" => "auth" })
    assert_equal ["auth.harmonic.social"], hosts
  end

  test "in single-tenant mode the allowed host is HOSTNAME without its port" do
    hosts = OmniAuthAllowedHosts.for_env({ "SINGLE_TENANT_MODE" => "true", "HOSTNAME" => "localhost:3000" })
    assert_equal ["localhost"], hosts
  end

  test "without HOSTNAME or AUTH_SUBDOMAIN no host is allowed, so the app still boots but OAuth fails closed" do
    assert_equal [], OmniAuthAllowedHosts.for_env({})
    assert_equal [], OmniAuthAllowedHosts.for_env({ "HOSTNAME" => "harmonic.social" })
    assert_equal [], OmniAuthAllowedHosts.for_env({ "SINGLE_TENANT_MODE" => "true", "HOSTNAME" => "" })
  end

  test "OmniAuth is configured with the auth host" do
    assert_equal [auth_host], OmniAuth.config.allowed_hosts
  end

  test "request phase on the auth host redirects to the provider" do
    host! auth_host
    post "/auth/github"
    assert_response :redirect
    assert_match %r{\Ahttps://github\.com/login/oauth/authorize}, response.location
  end

  test "request phase on a forged host fails with invalid_host" do
    host! "evil.example.com"
    post "/auth/github"
    assert_response :redirect
    assert_match %r{/auth/failure\?message=invalid_host}, response.location
  end

  test "request phase with a forged X-Forwarded-Host fails with invalid_host" do
    host! auth_host
    post "/auth/github", headers: { "X-Forwarded-Host" => "evil.example.com" }
    assert_response :redirect
    assert_match %r{/auth/failure\?message=invalid_host}, response.location
  end

  test "request phase on a tenant subdomain fails with invalid_host" do
    host! "app.#{ENV.fetch("HOSTNAME")}"
    post "/auth/github"
    assert_response :redirect
    assert_match %r{/auth/failure\?message=invalid_host}, response.location
  end
end
