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
end
