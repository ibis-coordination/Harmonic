require "test_helper"

class TenantUserTest < ActiveSupport::TestCase
  # Notification Preferences Tests

  test "notification type sets stay in sync across the three sources of truth" do
    # NOTIFICATION_TYPE_LABELS (UI + markdown surface), the default-preferences
    # matrix, and Notification::NOTIFICATION_TYPES (what actually gets emitted)
    # all enumerate the same types. Drift would silently drop a type from the
    # settings UI or leave it without a default.
    labels = TenantUser::NOTIFICATION_TYPE_LABELS.keys.sort
    defaults = TenantUser::DEFAULT_NOTIFICATION_PREFERENCES.keys.sort
    emitted = Notification::NOTIFICATION_TYPES.sort

    assert_equal emitted, labels, "NOTIFICATION_TYPE_LABELS keys must match Notification::NOTIFICATION_TYPES"
    assert_equal emitted, defaults, "DEFAULT_NOTIFICATION_PREFERENCES keys must match Notification::NOTIFICATION_TYPES"
  end

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

  test "notification_channels_for never returns email for a non-human user" do
    tenant, collective, parent = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    agent = create_ai_agent(parent: parent)
    agent_tenant_user = tenant.add_user!(agent)

    # Force email on in stored prefs; the channel must still be filtered out.
    agent_tenant_user.update_notification_preferences!("mention" => { "in_app" => true, "email" => true })

    channels = agent_tenant_user.notification_channels_for("mention")
    assert_includes channels, "in_app"
    refute_includes channels, "email", "agents have no routable address — email channel must be dropped"
  end

  test "update_notification_preferences! coerces email to false for a non-human user" do
    tenant, collective, parent = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    agent = create_ai_agent(parent: parent)
    agent_tenant_user = tenant.add_user!(agent)

    agent_tenant_user.update_notification_preferences!("mention" => { "email" => true })

    refute agent_tenant_user.notification_preferences["mention"]["email"],
      "agents must never persist a stored email:true"
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

  test "update_notification_preferences! applies a multi-type, multi-channel update" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    tenant_user.update_notification_preferences!(
      "mention" => { "email" => false },
      "comment" => { "email" => true, "in_app" => false },
    )
    tenant_user.reload

    refute tenant_user.notification_enabled?("mention", "email")
    assert tenant_user.notification_enabled?("mention", "in_app"), "untouched channel keeps its default"
    assert tenant_user.notification_enabled?("comment", "email")
    refute tenant_user.notification_enabled?("comment", "in_app")
  end

  test "update_notification_preferences! merges — types not supplied keep their existing values" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    tenant_user.set_notification_preference!("system", "email", false)
    tenant_user.update_notification_preferences!("mention" => { "email" => false })
    tenant_user.reload

    refute tenant_user.notification_enabled?("system", "email"), "earlier change is preserved"
    refute tenant_user.notification_enabled?("mention", "email")
  end

  test "update_notification_preferences! ignores unknown types and channels" do
    tenant, _collective, user = create_tenant_collective_user
    tenant_user = user.tenant_user

    tenant_user.update_notification_preferences!(
      "bogus_type" => { "email" => true },
      "comment" => { "carrier_pigeon" => true },
    )
    tenant_user.reload

    refute tenant_user.notification_preferences.key?("bogus_type")
    refute tenant_user.notification_preferences["comment"].key?("carrier_pigeon")
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

    assert_equal "Renamed-Handle", tu.reload.handle,
                 "settings renames slugify whitespace but preserve the chosen case"
  end

  test "explicit handle preserves the case the user chose" do
    tenant = create_tenant(subdomain: "hcase-#{SecureRandom.hex(4)}")
    user = create_user(email: "case-#{SecureRandom.hex(4)}@example.com", name: "Case User")
    tu = tenant.add_user!(user)

    tu.update!(handle: "Linus")

    assert_equal "Linus", tu.reload.handle, "display case must be remembered, not lowercased"
  end

  test "handle uniqueness is case-insensitive within a tenant" do
    tenant = create_tenant(subdomain: "hci-#{SecureRandom.hex(4)}")
    first = create_user(email: "ci1-#{SecureRandom.hex(4)}@example.com", name: "First")
    second = create_user(email: "ci2-#{SecureRandom.hex(4)}@example.com", name: "Second")
    tenant.add_user!(first).update!(handle: "linus")

    second_tu = tenant.add_user!(second)
    second_tu.handle = "Linus"

    assert_not second_tu.valid?, "\"Linus\" must collide with an existing \"linus\""
    assert_includes second_tu.errors[:handle].to_s.downcase, "taken"
  end

  test "a handle resolves regardless of the case it is looked up by" do
    tenant = create_tenant(subdomain: "hlk-#{SecureRandom.hex(4)}")
    user = create_user(email: "lk-#{SecureRandom.hex(4)}@example.com", name: "Lookup User")
    tenant.add_user!(user).update!(handle: "Linus")

    %w[linus LINUS Linus].each do |variant|
      assert_equal user.id,
                   tenant.tenant_users.find_by(handle: variant)&.user_id,
                   "@#{variant} should resolve to the same identity"
    end
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

  test "handle 'cadence' is allowed for an ai_agent with system_role 'cadence'" do
    tenant = create_tenant
    cadence = User.create!(
      email: "cadence_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Cadence", user_type: "ai_agent", system_role: "cadence", parent_id: nil,
    )
    tu = TenantUser.new(tenant: tenant, user: cadence, handle: "cadence", display_name: "Cadence")
    assert tu.valid?, tu.errors.full_messages.to_sentence
  end

  test "handle 'cadence' is rejected for a human user" do
    tenant = create_tenant
    user = create_user
    tu = TenantUser.new(tenant: tenant, user: user, handle: "cadence", display_name: user.name)
    assert_not tu.valid?
    assert_includes tu.errors[:handle].to_s.downcase, "reserved"
  end

  test "a cased variant of a reserved handle is still rejected for a human user" do
    # Case preservation must not let "Cadence"/"CADENCE" slip past the
    # reserved-handle gate, since the citext column treats them as the same
    # handle anyway.
    tenant = create_tenant
    user = create_user
    tu = TenantUser.new(tenant: tenant, user: user, handle: "Cadence", display_name: user.name)
    assert_not tu.valid?
    assert_includes tu.errors[:handle].to_s.downcase, "reserved"
  end

  test "handle 'cadence' is rejected for a non-cadence ai_agent" do
    tenant = create_tenant
    parent = create_user
    tenant.add_user!(parent)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    other_agent = User.create!(
      email: "agent_#{SecureRandom.hex(4)}@example.com",
      name: "Other Agent", user_type: "ai_agent", parent_id: parent.id,
    )
    tu = TenantUser.new(tenant: tenant, user: other_agent, handle: "cadence", display_name: "Cadence")
    assert_not tu.valid?
    assert_includes tu.errors[:handle].to_s.downcase, "reserved"
  end

  test "the ensemble handle 'trio' is rejected even for a system agent" do
    # @trio names the ensemble, not any single user — no system_role
    # entitles a record to claim it or its prefix.
    tenant = create_tenant
    cadence = User.create!(
      email: "cadence_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Cadence", user_type: "ai_agent", system_role: "cadence", parent_id: nil,
    )
    ["trio", "trio-engineering"].each do |handle|
      tu = TenantUser.new(tenant: tenant, user: cadence, handle: handle, display_name: "Cadence")
      assert_not tu.valid?, "#{handle} should be reserved even for system agents"
      assert_includes tu.errors[:handle].to_s.downcase, "reserved"
    end
  end

  test "group tag handles are rejected for a human user" do
    tenant = create_tenant
    ReservedHandles.group_tags.each do |tag|
      user = create_user(email: "gt-#{tag}-#{SecureRandom.hex(4)}@example.com")
      tu = TenantUser.new(tenant: tenant, user: user, handle: tag, display_name: user.name)
      assert_not tu.valid?, "#{tag} should be reserved"
      assert_includes tu.errors[:handle].to_s.downcase, "reserved"
    end
  end

  test "a group tag handle is rejected even for a system agent" do
    # Unlike @cadence, group tags never name a real user, so no system_role
    # entitles a record to claim them.
    tenant = create_tenant
    agent = User.create!(
      email: "sys_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Everyone", user_type: "ai_agent", system_role: "cadence", parent_id: nil,
    )
    tu = TenantUser.new(tenant: tenant, user: agent, handle: "everyone", display_name: "Everyone")
    assert_not tu.valid?
    assert_includes tu.errors[:handle].to_s.downcase, "reserved"
  end

  test "handle 'cadence' is rejected when set via update! on an existing TenantUser" do
    # Defense in depth: even if a caller bypasses the controller layer and
    # calls update! directly, the reserved-handle validation rejects
    # "cadence" for a non-cadence user.
    tenant = create_tenant(subdomain: "rh-update-#{SecureRandom.hex(4)}")
    user = create_user(email: "regular-#{SecureRandom.hex(4)}@example.com")
    tu = tenant.add_user!(user)
    assert_not_equal "cadence", tu.handle

    assert_raises(ActiveRecord::RecordInvalid) do
      tu.update!(handle: "cadence")
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

  # Web push channel

  test "notification_channels_for includes web_push when flag on, pref on, and an active subscription exists" do
    tenant, _collective, user = create_tenant_collective_user
    enable_web_push!(tenant)
    subscribe_to_push!(user)

    channels = user.tenant_user.notification_channels_for("mention")

    assert_includes channels, "web_push"
  end

  test "notification_channels_for excludes web_push when the tenant flag is off" do
    _tenant, _collective, user = create_tenant_collective_user
    subscribe_to_push!(user)

    channels = user.tenant_user.notification_channels_for("mention")

    refute_includes channels, "web_push"
  end

  test "notification_channels_for excludes web_push without an active subscription" do
    tenant, _collective, user = create_tenant_collective_user
    enable_web_push!(tenant)

    refute_includes user.tenant_user.notification_channels_for("mention"), "web_push"

    subscription = subscribe_to_push!(user)
    subscription.revoke!(reason: "gone")

    refute_includes user.tenant_user.notification_channels_for("mention"), "web_push"
  end

  test "notification_channels_for excludes web_push when the pref is off" do
    tenant, _collective, user = create_tenant_collective_user
    enable_web_push!(tenant)
    subscribe_to_push!(user)
    user.tenant_user.set_notification_preference!("mention", "web_push", false)

    refute_includes user.tenant_user.notification_channels_for("mention"), "web_push"
  end

  test "stored preferences that predate a channel fall back to that channel's default" do
    tenant, _collective, user = create_tenant_collective_user
    enable_web_push!(tenant)
    subscribe_to_push!(user)
    tenant_user = user.tenant_user

    # Simulate prefs saved before web_push existed: per-type hashes without
    # the key. A missing key must inherit the default (true), not read as off.
    tenant_user.settings["notification_preferences"] = {
      "mention" => { "in_app" => true, "email" => true },
      "tune_in" => { "in_app" => true, "email" => false },
    }
    tenant_user.save!

    assert_includes tenant_user.notification_channels_for("mention"), "web_push"
    assert_includes tenant_user.notification_channels_for("tune_in"), "web_push"
    assert tenant_user.notification_enabled?("mention", "web_push"),
           "the settings form must render the default state for channels missing from stored prefs"
    # Explicitly stored values still win over defaults.
    refute tenant_user.notification_enabled?("tune_in", "email")
  end

  test "notification_channels_for excludes web_push when the service_worker flag is off" do
    # Push physically requires the service worker (the push event fires inside
    # it, and unregistering it destroys the subscription), so web_push alone
    # must not light the channel up.
    tenant, _collective, user = create_tenant_collective_user
    tenant.enable_feature_flag!(:web_push)
    subscribe_to_push!(user)

    refute_includes user.tenant_user.notification_channels_for("mention"), "web_push"
  end

  test "notification_channels_for excludes web_push when VAPID keys are not configured" do
    tenant, _collective, user = create_tenant_collective_user
    enable_web_push!(tenant)
    subscribe_to_push!(user)

    old_key = ENV["VAPID_PUBLIC_KEY"]
    ENV["VAPID_PUBLIC_KEY"] = nil
    refute_includes user.tenant_user.notification_channels_for("mention"), "web_push"
  ensure
    ENV["VAPID_PUBLIC_KEY"] = old_key
  end

  test "update_notification_preferences! accepts the web_push channel" do
    tenant, _collective, user = create_tenant_collective_user
    enable_web_push!(tenant)
    subscribe_to_push!(user)

    user.tenant_user.update_notification_preferences!("comment" => { "web_push" => false })

    refute_includes user.tenant_user.notification_channels_for("comment"), "web_push"
    assert_includes user.tenant_user.notification_channels_for("mention"), "web_push"
  end

  private

  def subscribe_to_push!(user)
    WebPushSubscription.upsert_for!(
      user: user,
      endpoint: "https://push.example.com/send/#{SecureRandom.hex(4)}",
      p256dh_key: "p256dh-key",
      auth_key: "auth-key"
    )
  end

  def first_tenant_user_for_validation
    tenant = create_tenant(subdomain: "fields-#{SecureRandom.hex(4)}")
    user   = create_user(email: "fields-#{SecureRandom.hex(4)}@example.com")
    tenant.add_user!(user)
  end
end
