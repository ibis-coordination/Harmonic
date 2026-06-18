# typed: false

require "test_helper"

class Mcp::AudienceResolverTest < ActiveSupport::TestCase
  setup do
    @tenant = @global_tenant
    # @global_collective is non-main; the actual main_collective is what
    # resolves to "public".
    @main_collective = @tenant.main_collective
    @other_collective = @global_collective
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  teardown do
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "main collective resolves to public" do
    assert_equal "public", Mcp::AudienceResolver.resolve(capability_action: "create_note", collective: @main_collective)
  end

  test "non-main (invite-only) collective resolves to shared" do
    assert_equal "shared", Mcp::AudienceResolver.resolve(capability_action: "create_note", collective: @other_collective)
  end

  test "agent-private actions resolve to private regardless of collective" do
    %w[update_scratchpad dismiss dismiss_all dismiss_for_collective mark_read].each do |action|
      assert_equal "private",
                   Mcp::AudienceResolver.resolve(capability_action: action, collective: nil),
                   "expected #{action.inspect} to be private (no collective)"
      assert_equal "private",
                   Mcp::AudienceResolver.resolve(capability_action: action, collective: @main_collective),
                   "expected #{action.inspect} to be private even with main collective set"
    end
  end

  test "non-collective writes that aren't agent-private resolve to shared" do
    %w[create_api_token update_profile create_collective start_representation].each do |action|
      assert_equal "shared",
                   Mcp::AudienceResolver.resolve(capability_action: action, collective: nil),
                   "expected #{action.inspect} to be shared when no collective is set"
    end
  end

  test "nil capability_action with a main collective still resolves to public" do
    assert_equal "public", Mcp::AudienceResolver.resolve(capability_action: nil, collective: @main_collective)
  end

  test "nil capability_action with no collective resolves to shared" do
    assert_equal "shared", Mcp::AudienceResolver.resolve(capability_action: nil, collective: nil)
  end
end
