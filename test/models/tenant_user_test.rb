require "test_helper"

class TenantUserTest < ActiveSupport::TestCase
  # Notification Preferences Tests

  test "notification_preferences returns defaults when not set" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    prefs = tenant_user.notification_preferences

    assert prefs["mention"]["in_app"]
    assert prefs["mention"]["email"]
    assert prefs["comment"]["in_app"]
    refute prefs["comment"]["email"]
    assert prefs["participation"]["in_app"]
    refute prefs["participation"]["email"]
    assert prefs["system"]["in_app"]
    assert prefs["system"]["email"]
  end

  test "notification_channels_for returns correct channels based on defaults" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    # Mention defaults to both channels
    channels = tenant_user.notification_channels_for("mention")
    assert_includes channels, "in_app"
    assert_includes channels, "email"

    # Comment defaults to in_app only
    channels = tenant_user.notification_channels_for("comment")
    assert_includes channels, "in_app"
    refute_includes channels, "email"
  end

  test "notification_enabled? returns correct status" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    assert tenant_user.notification_enabled?("mention", "in_app")
    assert tenant_user.notification_enabled?("mention", "email")
    assert tenant_user.notification_enabled?("comment", "in_app")
    refute tenant_user.notification_enabled?("comment", "email")
  end

  test "set_notification_preference! updates preference" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    # Disable email for mentions
    tenant_user.set_notification_preference!("mention", "email", false)
    refute tenant_user.notification_enabled?("mention", "email")

    # Enable email for comments
    tenant_user.set_notification_preference!("comment", "email", true)
    assert tenant_user.notification_enabled?("comment", "email")

    # Verify the changes persist after reload
    tenant_user.reload
    refute tenant_user.notification_enabled?("mention", "email")
    assert tenant_user.notification_enabled?("comment", "email")
  end

  test "notification_channels_for respects custom preferences" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    # Customize preferences
    tenant_user.set_notification_preference!("mention", "email", false)
    tenant_user.set_notification_preference!("comment", "email", true)

    # Check mention now only has in_app
    channels = tenant_user.notification_channels_for("mention")
    assert_equal ["in_app"], channels

    # Check comment now has both
    channels = tenant_user.notification_channels_for("comment")
    assert_includes channels, "in_app"
    assert_includes channels, "email"
  end

  test "notification_channels_for returns empty array when all disabled" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    # Disable all channels for a notification type
    tenant_user.set_notification_preference!("comment", "in_app", false)
    tenant_user.set_notification_preference!("comment", "email", false)

    channels = tenant_user.notification_channels_for("comment")
    assert_empty channels
  end

  test "notification_channels_for handles unknown notification type" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    # Unknown type should return empty array
    channels = tenant_user.notification_channels_for("unknown_type")
    assert_empty channels
  end

  # === Reserved handles ===

  test "handle 'trio' is allowed for an ai_agent with system_role 'trio'" do
    tenant = create_tenant
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    tu = TenantUser.new(tenant: tenant, user: trio, handle: "trio", display_name: "Trio")
    assert tu.valid?, tu.errors.full_messages.to_sentence
  end

  test "handle 'trio' is rejected for a human user" do
    tenant = create_tenant
    user = create_user
    tu = TenantUser.new(tenant: tenant, user: user, handle: "trio", display_name: user.name)
    assert_not tu.valid?
    assert_includes tu.errors[:handle].to_s.downcase, "reserved"
  end

  test "handle 'trio' is rejected for a non-trio ai_agent" do
    tenant = create_tenant
    parent = create_user
    tenant.add_user!(parent)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    other_agent = User.create!(
      email: "agent_#{SecureRandom.hex(4)}@example.com",
      name: "Other Agent", user_type: "ai_agent", parent_id: parent.id,
    )
    tu = TenantUser.new(tenant: tenant, user: other_agent, handle: "trio", display_name: "Trio")
    assert_not tu.valid?
    assert_includes tu.errors[:handle].to_s.downcase, "reserved"
  end
end
