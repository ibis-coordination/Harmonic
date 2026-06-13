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

    # tune_in defaults to in_app only — tune-ins can be high-volume and
    # shouldn't push users to disable email entirely.
    channels = tenant_user.notification_channels_for("tune_in")
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

  # === Handle generation ===

  test "add_user! generates a unique handle when another tenant user already has the name-derived one" do
    tenant = create_tenant(subdomain: "hgen-#{SecureRandom.hex(4)}")
    first = create_user(email: "smith1-#{SecureRandom.hex(4)}@example.com", name: "Jane Smith")
    second = create_user(email: "smith2-#{SecureRandom.hex(4)}@example.com", name: "Jane Smith")

    first_tu = tenant.add_user!(first)
    assert_equal "jane-smith", first_tu.handle

    second_tu = tenant.add_user!(second)
    assert_not_equal first_tu.handle, second_tu.handle,
                     "two users with the same name must not collide on handle"
    assert_match(/\Ajane-smith-/, second_tu.handle,
                 "expected the derived handle with a uniquifying suffix")
  end

  test "default handle prefers the user's external OAuth username over their name" do
    tenant = create_tenant(subdomain: "hoauth-#{SecureRandom.hex(4)}")
    user = create_user(email: "gh-#{SecureRandom.hex(4)}@example.com", name: "Jane Smith")
    OauthIdentity.create!(provider: "github", uid: SecureRandom.hex(6), user: user, username: "JaneSmith-Dev")

    tu = tenant.add_user!(user)

    assert_equal "janesmith-dev", tu.handle,
                 "expected the GitHub username (parameterized), not the name-derived handle"
  end

  test "default handle falls back to the name when the external OAuth identity has no username" do
    tenant = create_tenant(subdomain: "hnouser-#{SecureRandom.hex(4)}")
    user = create_user(email: "nouser-#{SecureRandom.hex(4)}@example.com", name: "Sam Jones")
    OauthIdentity.create!(provider: "github", uid: SecureRandom.hex(6), user: user, username: nil)

    tu = tenant.add_user!(user)

    assert_equal "sam-jones", tu.handle
  end

  test "default handle falls back to a neutral base for names with no parameterizable characters" do
    tenant = create_tenant(subdomain: "hcjk-#{SecureRandom.hex(4)}")
    user = create_user(email: "cjk-#{SecureRandom.hex(4)}@example.com", name: "山田太郎")

    tu = tenant.add_user!(user)

    assert_match(/\Auser(-\h{4})?\z/, tu.handle,
                 "expected a usable fallback handle, not an empty string")
  end

  test "handle is normalized on assignment for every writer" do
    tenant = create_tenant(subdomain: "hnorm-#{SecureRandom.hex(4)}")
    user = create_user(email: "norm-#{SecureRandom.hex(4)}@example.com", name: "Norm Writer")
    tu = tenant.add_user!(user)

    tu.update!(handle: "Renamed Handle")

    assert_equal "renamed-handle", tu.reload.handle,
                 "settings renames must normalize the same way signup does"
  end

  test "an explicit duplicate handle fails validation instead of crashing on the DB constraint" do
    tenant = create_tenant(subdomain: "hdup-#{SecureRandom.hex(4)}")
    first = create_user(email: "hdup1-#{SecureRandom.hex(4)}@example.com", name: "First User")
    second = create_user(email: "hdup2-#{SecureRandom.hex(4)}@example.com", name: "Second User")
    tenant.add_user!(first, handle: "wanted-handle")

    error = assert_raises(ActiveRecord::RecordInvalid) do
      tenant.add_user!(second, handle: "wanted-handle")
    end
    assert_match(/taken/i, error.message)
  end

  test "add_user! with an identical name works in a different tenant without suffixing" do
    tenant_a = create_tenant(subdomain: "hgena-#{SecureRandom.hex(4)}")
    tenant_b = create_tenant(subdomain: "hgenb-#{SecureRandom.hex(4)}")
    user_a = create_user(email: "ta-#{SecureRandom.hex(4)}@example.com", name: "Pat Doe")
    user_b = create_user(email: "tb-#{SecureRandom.hex(4)}@example.com", name: "Pat Doe")

    tenant_a.add_user!(user_a)
    tu_b = tenant_b.add_user!(user_b)

    assert_equal "pat-doe", tu_b.handle, "handle uniqueness is per-tenant"
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

  test "handle 'trio' is rejected when set via update! on an existing TenantUser" do
    # Defense in depth: even if a caller bypasses the controller layer and
    # calls update! directly, the reserved-handle validation rejects "trio"
    # for a non-trio user.
    tenant = create_tenant(subdomain: "rh-update-#{SecureRandom.hex(4)}")
    user = create_user(email: "regular-#{SecureRandom.hex(4)}@example.com")
    tu = tenant.add_user!(user)
    assert_not_equal "trio", tu.handle

    assert_raises(ActiveRecord::RecordInvalid) do
      tu.update!(handle: "trio")
    end
  end

  # === Profile fields: bio / location / website ===

  test "bio is valid when blank" do
    tu = first_tenant_user_for_validation
    tu.bio = nil
    assert tu.valid?
  end

  test "bio rejects values longer than 500 chars" do
    tu = first_tenant_user_for_validation
    tu.bio = "x" * 501
    assert_not tu.valid?
    assert_includes tu.errors[:bio].to_s, "too long"
  end

  test "bio accepts exactly 500 chars" do
    tu = first_tenant_user_for_validation
    tu.bio = "x" * 500
    assert tu.valid?, tu.errors.full_messages.to_sentence
  end

  test "location rejects values longer than 100 chars" do
    tu = first_tenant_user_for_validation
    tu.location = "x" * 101
    assert_not tu.valid?
    assert_includes tu.errors[:location].to_s, "too long"
  end

  test "website accepts an https URL" do
    tu = first_tenant_user_for_validation
    tu.website = "https://example.com"
    assert tu.valid?, tu.errors.full_messages.to_sentence
  end

  test "website accepts an http URL" do
    tu = first_tenant_user_for_validation
    tu.website = "http://example.com"
    assert tu.valid?, tu.errors.full_messages.to_sentence
  end

  test "website rejects a non-http(s) scheme" do
    tu = first_tenant_user_for_validation
    tu.website = "javascript:alert(1)"
    assert_not tu.valid?
    assert_includes tu.errors[:website].to_s, "http"
  end

  test "website rejects a URL without a hostname" do
    tu = first_tenant_user_for_validation
    tu.website = "https://"
    assert_not tu.valid?
  end

  test "website is valid when blank" do
    tu = first_tenant_user_for_validation
    tu.website = nil
    assert tu.valid?
  end

  private

  def first_tenant_user_for_validation
    tenant = create_tenant(subdomain: "fields-#{SecureRandom.hex(4)}")
    user   = create_user(email: "fields-#{SecureRandom.hex(4)}@example.com")
    tenant.add_user!(user)
  end
end
