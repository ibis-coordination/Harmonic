# typed: false

require "test_helper"
require_relative "component_test_helper"

class SidebarComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  def build_main_collective
    collective = build_collective(name: "Main", handle: "main")
    main_id = SecureRandom.uuid
    collective.define_singleton_method(:id) { main_id }
    tenant = Tenant.new
    tenant.define_singleton_method(:main_collective_id) { main_id }
    collective.define_singleton_method(:tenant) { tenant }
    collective
  end

  def build_regular_collective
    collective = build_collective(name: "Team", handle: "team")
    collective.define_singleton_method(:id) { SecureRandom.uuid }
    tenant = Tenant.new
    tenant.define_singleton_method(:main_collective_id) { "other-id" }
    collective.define_singleton_method(:tenant) { tenant }
    collective
  end

  test "resolved_mode defaults to full" do
    component = SidebarComponent.new
    assert_equal "full", component.resolved_mode
  end

  test "resolved_mode passes through requested mode for regular collective" do
    component = SidebarComponent.new(requested_mode: "resource", collective: build_regular_collective)
    assert_equal "resource", component.resolved_mode
  end

  test "resolved_mode becomes none for main collective with full mode" do
    component = SidebarComponent.new(requested_mode: "full", collective: build_main_collective)
    assert_equal "none", component.resolved_mode
  end

  test "resolved_mode becomes none for main collective with resource mode" do
    component = SidebarComponent.new(requested_mode: "resource", collective: build_main_collective)
    assert_equal "none", component.resolved_mode
  end

  test "resolved_mode becomes none for main collective with minimal mode" do
    component = SidebarComponent.new(requested_mode: "minimal", collective: build_main_collective)
    assert_equal "none", component.resolved_mode
  end

  test "admin modes are not overridden by main collective" do
    %w[system_admin app_admin tenant_admin].each do |mode|
      component = SidebarComponent.new(requested_mode: mode, collective: build_main_collective)
      assert_equal mode, component.resolved_mode, "#{mode} should not be overridden for main collective"
    end
  end

  test "invalid mode falls back to full" do
    component = SidebarComponent.new(requested_mode: "bogus")
    assert_equal "full", component.resolved_mode
  end

  test "nil collective is handled gracefully" do
    component = SidebarComponent.new(requested_mode: "resource", collective: nil)
    assert_equal "resource", component.resolved_mode
  end

  test "no-sidebar class applied when mode is none" do
    component = SidebarComponent.new(requested_mode: "none")
    assert_equal "none", component.resolved_mode
  end

  test "no-sidebar class applied for main collective" do
    component = SidebarComponent.new(requested_mode: "full", collective: build_main_collective)
    assert_equal "none", component.resolved_mode
  end
end
