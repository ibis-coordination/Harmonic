# typed: false
require "test_helper"

# Web servers (Puma) reuse threads across requests. Any thread-local state
# that accumulates rather than being overwritten at the start of each request
# leaks from one request into the next. AutomationContext's chain state is
# exactly this shape (executed_rule_ids is a growing Set), so
# ApplicationController must clear it at the start of every request.
#
# Without this, an automation rule that successfully fires once will be
# silently suppressed on every subsequent matching event served by the same
# thread — "loop detected" — until the process restarts.
class ApplicationControllerThreadStateTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}"
    sign_in_as(@user, tenant: @tenant)
  end

  teardown do
    AutomationContext.clear_chain!
  end

  test "clears stale AutomationContext chain at request start" do
    # Simulate state left over from a prior request on the same thread.
    fake_rule_id = SecureRandom.uuid
    AutomationContext.restore_chain!(
      "depth" => 2,
      "executed_rule_ids" => [fake_rule_id],
      "origin_event_id" => SecureRandom.uuid,
    )
    assert_includes AutomationContext.current_chain[:executed_rule_ids], fake_rule_id,
      "sanity check: chain should contain the polluted rule before request"
    assert_equal 2, AutomationContext.chain_depth

    get "/collectives/#{@collective.handle}"
    assert_response :success

    assert_not_includes AutomationContext.current_chain[:executed_rule_ids], fake_rule_id,
      "request should have cleared stale chain state from prior work"
    assert_equal 0, AutomationContext.chain_depth
  end
end
