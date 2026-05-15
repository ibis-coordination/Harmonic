# typed: false

require "test_helper"

class TrioSeederTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant(subdomain: "trio-seeder-#{SecureRandom.hex(4)}")
    @owner = create_user(email: "owner_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@owner)
    @tenant.create_main_collective!(created_by: @owner)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  teardown do
    Tenant.clear_thread_scope
  end

  test "ensure_for creates a trio user when none exists" do
    trio = TrioSeeder.ensure_for(@tenant)

    assert trio.persisted?
    assert_equal "ai_agent", trio.user_type
    assert_equal "trio", trio.system_role
    assert_nil trio.parent_id
    assert_equal "Trio", trio.name
  end

  test "ensure_for is idempotent" do
    first = TrioSeeder.ensure_for(@tenant)
    second = TrioSeeder.ensure_for(@tenant)

    assert_equal first.id, second.id
    assert_equal 1, User.system_agents.joins(:tenant_users).where(tenant_users: { tenant_id: @tenant.id }).count
  end

  test "trio is a member of the tenant's main collective" do
    trio = TrioSeeder.ensure_for(@tenant)

    main_collective = T.must(@tenant.main_collective)
    assert main_collective.user_is_member?(trio)
  end

  test "trio has handle 'trio'" do
    trio = TrioSeeder.ensure_for(@tenant)

    assert_equal "trio", trio.tenant_users.find_by(tenant_id: @tenant.id).handle
  end

  test "trio is configured as an internal ai_agent" do
    trio = TrioSeeder.ensure_for(@tenant)

    assert trio.internal_ai_agent?
    assert_equal "internal", trio.agent_configuration["mode"]
  end

  test "trio resolves its identity prompt from the static source" do
    trio = TrioSeeder.ensure_for(@tenant)

    assert_equal Trio::SystemPrompt.text, trio.effective_identity_prompt
  end

  test "trio's agent_configuration does not cache identity_prompt" do
    trio = TrioSeeder.ensure_for(@tenant)

    # No stale snapshot — User#effective_identity_prompt reads from the
    # static source instead, so /whoami always renders the latest prompt
    # without requiring a re-seed.
    assert_nil trio.agent_configuration["identity_prompt"]
  end

  test "ensure_for clears any pre-existing cached identity_prompt" do
    trio = TrioSeeder.ensure_for(@tenant)
    trio.update!(agent_configuration: trio.agent_configuration.merge("identity_prompt" => "stale prompt"))

    TrioSeeder.ensure_for(@tenant)

    assert_nil trio.reload.agent_configuration["identity_prompt"]
  end

  test "trio has no stripe_customer" do
    trio = TrioSeeder.ensure_for(@tenant)

    assert_nil trio.stripe_customer
    assert_nil trio.billing_customer
  end

  test "trio does not create a TrusteeGrant" do
    assert_difference -> { TrusteeGrant.count }, 0 do
      TrioSeeder.ensure_for(@tenant)
    end
  end

  test "ensure_for on separate tenants creates separate trio users" do
    other_tenant = create_tenant(subdomain: "trio-other-#{SecureRandom.hex(4)}")
    other_owner = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    other_tenant.add_user!(other_owner)
    other_tenant.create_main_collective!(created_by: other_owner)

    trio_a = TrioSeeder.ensure_for(@tenant)

    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    trio_b = TrioSeeder.ensure_for(other_tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    assert_not_equal trio_a.id, trio_b.id
  end

  # The previous per-tenant seeder needed a "fall back when 'trio' is taken"
  # path because nothing prevented a regular user from claiming the handle.
  # That case is now structurally impossible: TenantUser validates that
  # handle "trio" is only claimable by a user with system_role == "trio".
  # The fallback test was removed with that validation.
end
