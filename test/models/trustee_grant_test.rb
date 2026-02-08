require "test_helper"

class TrusteeGrantTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "trustee-perm-#{SecureRandom.hex(4)}")
    @granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @trusted_user = create_user(email: "trusted_#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @tenant.add_user!(@granting_user)
    @tenant.add_user!(@trusted_user)
    @superagent = create_superagent(tenant: @tenant, created_by: @granting_user, handle: "trustee-perm-studio-#{SecureRandom.hex(4)}")
    @superagent.add_user!(@granting_user)
    @superagent.add_user!(@trusted_user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  # =========================================================================
  # BASIC CREATION AND VALIDATION
  # =========================================================================

  test "trustee permission can be created with valid attributes" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
    )
    assert permission.persisted?
    assert permission.trustee_user.present?
    assert permission.trustee_user.trustee?
  end

  test "trustee permission auto-creates a trustee user" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
    )
    trustee = permission.trustee_user
    assert trustee.present?
    assert trustee.trustee?
    assert_not trustee.superagent_trustee?
    assert_equal "Bob acts for Alice", trustee.name
  end

  test "granting_user cannot be the same as trusted_user" do
    permission = TrusteeGrant.new(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @granting_user,
      relationship_phrase: "self delegation",
      permissions: {},
    )
    assert_not permission.valid?
    assert_includes permission.errors[:trusted_user], "cannot be the same as the granting user"
  end

  test "trusted_user cannot be a trustee user" do
    some_trustee = User.create!(
      email: "#{SecureRandom.uuid}@not-a-real-email.com",
      name: "Some Trustee",
      user_type: "trustee",
    )
    permission = TrusteeGrant.new(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: some_trustee,
      relationship_phrase: "trustee as trusted",
      permissions: {},
    )
    assert_not permission.valid?
    assert_includes permission.errors[:trusted_user], "cannot be a trustee user"
  end

  # =========================================================================
  # ACCEPTANCE WORKFLOW - STATE TRANSITIONS
  # =========================================================================

  test "newly created permission is in pending state" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    assert permission.pending?
    assert_not permission.active?
    assert_not permission.declined?
    assert_not permission.revoked?
  end

  test "accept! transitions permission from pending to active" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    assert permission.pending?

    permission.accept!

    assert_not permission.pending?
    assert permission.active?
    assert permission.accepted_at.present?
  end

  test "accept! raises error if permission is not pending" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!

    assert_raises RuntimeError, /Cannot accept: not pending/ do
      permission.accept!
    end
  end

  test "decline! transitions permission from pending to declined" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    assert permission.pending?

    permission.decline!

    assert_not permission.pending?
    assert permission.declined?
    assert permission.declined_at.present?
    assert_not permission.active?
  end

  test "decline! raises error if permission is not pending" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!

    assert_raises RuntimeError, /Cannot decline: not pending/ do
      permission.decline!
    end
  end

  test "revoke! transitions permission from active to revoked" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!
    assert permission.active?

    permission.revoke!

    assert permission.revoked?
    assert permission.revoked_at.present?
    assert_not permission.active?
  end

  test "revoke! raises error if permission is already revoked" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!
    permission.revoke!

    assert_raises RuntimeError, /Cannot revoke: already revoked or declined/ do
      permission.revoke!
    end
  end

  test "revoke! raises error if permission is declined" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.decline!

    assert_raises RuntimeError, /Cannot revoke: already revoked or declined/ do
      permission.revoke!
    end
  end

  # =========================================================================
  # EXPIRATION
  # =========================================================================

  test "expired? returns true when expires_at is in the past" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      expires_at: 1.hour.ago,
    )
    permission.accept!

    assert permission.expired?
    assert_not permission.active?, "Expired permission should not be active"
  end

  test "expired? returns false when expires_at is in the future" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      expires_at: 1.week.from_now,
    )
    permission.accept!

    assert_not permission.expired?
    assert permission.active?
  end

  test "expired? returns false when expires_at is nil" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      expires_at: nil,
    )
    permission.accept!

    assert_not permission.expired?
    assert permission.active?
  end

  # =========================================================================
  # ACTION PERMISSIONS
  # =========================================================================

  test "has_action_permission? returns true for granted action" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true, "vote" => true },
    )

    assert permission.has_action_permission?("create_note")
    assert permission.has_action_permission?("vote")
  end

  test "has_action_permission? returns false for non-granted action" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    assert_not permission.has_action_permission?("vote")
    assert_not permission.has_action_permission?("join_commitment")
  end

  test "has_action_permission? returns false for explicitly denied action" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true, "vote" => false },
    )

    assert permission.has_action_permission?("create_note")
    assert_not permission.has_action_permission?("vote")
  end

  test "has_action_permission? returns true for all actions when permissions is nil" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: nil,
    )

    assert permission.has_action_permission?("create_note")
    assert permission.has_action_permission?("vote")
    assert permission.has_action_permission?("any_action")
  end

  test "GRANTABLE_ACTIONS constant defines valid action names" do
    assert TrusteeGrant::GRANTABLE_ACTIONS.is_a?(Array)
    assert TrusteeGrant::GRANTABLE_ACTIONS.include?("create_note")
    assert TrusteeGrant::GRANTABLE_ACTIONS.include?("vote")
    assert TrusteeGrant::GRANTABLE_ACTIONS.include?("join_commitment")
  end

  # =========================================================================
  # STUDIO SCOPING
  # =========================================================================

  test "allows_studio? returns true when mode is 'all'" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
      studio_scope: { "mode" => "all" },
    )

    assert permission.allows_studio?(@superagent)
  end

  test "allows_studio? returns true when studio is in include list" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
      studio_scope: { "mode" => "include", "studio_ids" => [@superagent.id] },
    )

    assert permission.allows_studio?(@superagent)
  end

  test "allows_studio? returns false when studio is not in include list" do
    other_studio = create_superagent(tenant: @tenant, created_by: @granting_user, handle: "other-studio-#{SecureRandom.hex(4)}")

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
      studio_scope: { "mode" => "include", "studio_ids" => [other_studio.id] },
    )

    assert_not permission.allows_studio?(@superagent)
    assert permission.allows_studio?(other_studio)
  end

  test "allows_studio? returns false when studio is in exclude list" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
      studio_scope: { "mode" => "exclude", "studio_ids" => [@superagent.id] },
    )

    assert_not permission.allows_studio?(@superagent)
  end

  test "allows_studio? returns true when studio is not in exclude list" do
    other_studio = create_superagent(tenant: @tenant, created_by: @granting_user, handle: "other-studio-#{SecureRandom.hex(4)}")

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
      studio_scope: { "mode" => "exclude", "studio_ids" => [other_studio.id] },
    )

    assert permission.allows_studio?(@superagent)
    assert_not permission.allows_studio?(other_studio)
  end

  test "allows_studio? defaults to mode 'all' when studio_scope is nil" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: {},
      studio_scope: nil,
    )

    assert permission.allows_studio?(@superagent)
  end

  # =========================================================================
  # SCOPES
  # =========================================================================

  test "pending scope returns only pending permissions" do
    pending_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "pending",
      permissions: {},
    )

    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other")
    @tenant.add_user!(other_user)
    accepted_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: other_user,
      relationship_phrase: "accepted",
      permissions: {},
    )
    accepted_permission.accept!

    pending_permissions = TrusteeGrant.pending
    assert_includes pending_permissions, pending_permission
    assert_not_includes pending_permissions, accepted_permission
  end

  test "active scope returns only active (accepted, not expired, not revoked) permissions" do
    # Pending permission
    pending_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "pending",
      permissions: {},
    )

    # Active permission
    other_user1 = create_user(email: "other1_#{SecureRandom.hex(4)}@example.com", name: "Other1")
    @tenant.add_user!(other_user1)
    active_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: other_user1,
      relationship_phrase: "active",
      permissions: {},
    )
    active_permission.accept!

    # Expired permission
    other_user2 = create_user(email: "other2_#{SecureRandom.hex(4)}@example.com", name: "Other2")
    @tenant.add_user!(other_user2)
    expired_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: other_user2,
      relationship_phrase: "expired",
      permissions: {},
      expires_at: 1.hour.ago,
    )
    expired_permission.update!(accepted_at: 2.hours.ago) # Manually set to simulate expired active

    # Revoked permission
    other_user3 = create_user(email: "other3_#{SecureRandom.hex(4)}@example.com", name: "Other3")
    @tenant.add_user!(other_user3)
    revoked_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: other_user3,
      relationship_phrase: "revoked",
      permissions: {},
    )
    revoked_permission.accept!
    revoked_permission.revoke!

    active_permissions = TrusteeGrant.active
    assert_includes active_permissions, active_permission
    assert_not_includes active_permissions, pending_permission
    assert_not_includes active_permissions, expired_permission
    assert_not_includes active_permissions, revoked_permission
  end

  # =========================================================================
  # UNIQUE CONSTRAINT
  # =========================================================================

  test "cannot create duplicate active permission for same granting and trusted user pair" do
    TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "first permission",
      permissions: {},
    )

    # Second active permission for same pair should fail
    assert_raises ActiveRecord::RecordNotUnique do
      TrusteeGrant.create!(
        tenant: @tenant,
        granting_user: @granting_user,
        trusted_user: @trusted_user,
        relationship_phrase: "second permission",
        permissions: {},
      )
    end
  end

  test "can create new permission after previous one is revoked" do
    first_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "first permission",
      permissions: {},
    )
    first_permission.accept!
    first_permission.revoke!

    # Should be able to create new permission now
    second_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "second permission",
      permissions: {},
    )
    assert second_permission.persisted?
  end

  test "can create new permission after previous one is declined" do
    first_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "first permission",
      permissions: {},
    )
    first_permission.decline!

    # Should be able to create new permission now
    second_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trusted_user: @trusted_user,
      relationship_phrase: "second permission",
      permissions: {},
    )
    assert second_permission.persisted?
  end
end
