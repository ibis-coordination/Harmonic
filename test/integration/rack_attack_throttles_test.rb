# typed: false
require "test_helper"

# Pins the rack_attack throttles that protect the auth-flow endpoints. The
# functional rate-limit isn't exercised here (Rack::Attack isn't invoked in
# the integration test stack), but we assert each throttle's matcher is
# registered for the path/method we expect — so a refactor that breaks the
# regex causes a test failure rather than silent loss of protection.
class RackAttackThrottlesTest < ActiveSupport::TestCase
  def matches?(rule_name, path:, method: "POST", **env_extras)
    rule = Rack::Attack.throttles[rule_name]
    refute_nil rule, "expected throttle '#{rule_name}' to be registered in rack_attack.rb"
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => "1.2.3.4", **env_extras)
    req = Rack::Attack::Request.new(env)
    rule.block.call(req)
  end

  test "invite_required/ip throttle matches POST /invite-required" do
    assert_equal "1.2.3.4", matches?("invite_required/ip", path: "/invite-required", method: "POST")
    assert_nil matches?("invite_required/ip", path: "/invite-required", method: "GET")
    assert_nil matches?("invite_required/ip", path: "/something-else", method: "POST")
  end

  test "invite_required/user throttle pulls user_id from session for POST /invite-required" do
    rule = Rack::Attack.throttles["invite_required/user"]
    refute_nil rule, "expected throttle 'invite_required/user' to be registered"

    session = { "user_id" => 42 }
    env = Rack::MockRequest.env_for("/invite-required", method: "POST", "REMOTE_ADDR" => "1.2.3.4")
    env["rack.session"] = session
    req = Rack::Attack::Request.new(env)
    assert_equal 42, rule.block.call(req)

    # Different path: nil
    env2 = Rack::MockRequest.env_for("/login", method: "POST", "REMOTE_ADDR" => "1.2.3.4")
    env2["rack.session"] = session
    req2 = Rack::Attack::Request.new(env2)
    assert_nil rule.block.call(req2)
  end

  test "invite_required/user is a no-op when there's no session user_id" do
    rule = Rack::Attack.throttles["invite_required/user"]
    env = Rack::MockRequest.env_for("/invite-required", method: "POST", "REMOTE_ADDR" => "1.2.3.4")
    env["rack.session"] = {}
    req = Rack::Attack::Request.new(env)
    assert_nil rule.block.call(req)
  end

  test "accept_invite/ip throttle matches POST /invite-required/accept" do
    assert_equal "1.2.3.4", matches?("accept_invite/ip", path: "/invite-required/accept", method: "POST")
    assert_nil matches?("accept_invite/ip", path: "/invite-required/accept", method: "GET")
    assert_nil matches?("accept_invite/ip", path: "/invite-required", method: "POST")
  end

  test "identity_register/ip throttle matches POST /auth/identity/register" do
    assert_equal "1.2.3.4", matches?("identity_register/ip", path: "/auth/identity/register", method: "POST")
    assert_nil matches?("identity_register/ip", path: "/auth/identity/register", method: "GET")
    assert_nil matches?("identity_register/ip", path: "/auth/identity/callback", method: "POST")
  end
end
