# typed: false

require "test_helper"

class TrioSeederTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant(subdomain: "trio-seeder-#{SecureRandom.hex(4)}")
    @owner = create_user(email: "owner_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@owner)
    @tenant.create_main_collective!(created_by: @owner)
    @main = T.must(@tenant.main_collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  teardown do
    Tenant.clear_thread_scope
  end

  test "ensure_for creates a trio user when none exists" do
    trio = TrioSeeder.ensure_for(@main)

    assert trio.persisted?
    assert_equal "ai_agent", trio.user_type
    assert_equal "trio", trio.system_role
    assert_equal "Trio", trio.name
  end

  test "trio's principal is the collective's identity user" do
    trio = TrioSeeder.ensure_for(@main)

    assert_equal @main.identity_user_id, trio.parent_id
  end

  test "each collective's trio is principaled by that collective's own identity" do
    other = create_collective(tenant: @tenant, created_by: @owner)

    trio_main = TrioSeeder.ensure_for(@main)
    trio_other = TrioSeeder.ensure_for(other)

    assert_equal @main.identity_user_id, trio_main.parent_id
    assert_equal other.identity_user_id, trio_other.parent_id
    assert_not_equal trio_main.parent_id, trio_other.parent_id
  end

  test "ensure_for is idempotent" do
    first = TrioSeeder.ensure_for(@main)
    second = TrioSeeder.ensure_for(@main)

    assert_equal first.id, second.id
  end

  test "ensure_for assigns collective.trio_user" do
    trio = TrioSeeder.ensure_for(@main)

    assert_equal trio.id, @main.reload.trio_user_id
  end

  test "trio is a CollectiveMember of its collective" do
    trio = TrioSeeder.ensure_for(@main)

    assert @main.user_is_member?(trio)
  end

  test "main collective's trio has handle 'trio'" do
    trio = TrioSeeder.ensure_for(@main)

    assert_equal "trio", trio.tenant_users.find_by(tenant_id: @tenant.id).handle
  end

  test "non-main collective's trio has a 'trio-<hex>' handle" do
    other = create_collective(tenant: @tenant, created_by: @owner)
    trio = TrioSeeder.ensure_for(other)
    handle = trio.tenant_users.find_by(tenant_id: @tenant.id).handle

    assert_match(/\Atrio-[a-f0-9]+\z/, handle)
    assert_not_equal "trio", handle
  end

  test "trio is configured as an internal ai_agent" do
    trio = TrioSeeder.ensure_for(@main)

    assert trio.internal_ai_agent?
    assert_equal "internal", trio.agent_configuration["mode"]
  end

  test "trio is seeded with the model from TRIO_DEFAULT_MODEL env var" do
    previous = ENV["TRIO_DEFAULT_MODEL"]
    ENV["TRIO_DEFAULT_MODEL"] = "trinity-large-thinking-free"

    trio = TrioSeeder.ensure_for(@main)

    assert_equal "trinity-large-thinking-free", trio.agent_configuration["model"]
  ensure
    ENV["TRIO_DEFAULT_MODEL"] = previous
  end

  test "trio omits the model key when TRIO_DEFAULT_MODEL is unset" do
    previous = ENV["TRIO_DEFAULT_MODEL"]
    ENV.delete("TRIO_DEFAULT_MODEL")

    trio = TrioSeeder.ensure_for(@main)

    assert_not trio.agent_configuration.key?("model"),
      "expected model key absent so the agent-runner falls back to its default model alias"
  ensure
    ENV["TRIO_DEFAULT_MODEL"] = previous
  end

  test "trio resolves its identity prompt from the static source" do
    trio = TrioSeeder.ensure_for(@main)

    assert_equal Trio::SystemPrompt.text, trio.effective_identity_prompt
  end

  test "trio's agent_configuration does not cache identity_prompt" do
    trio = TrioSeeder.ensure_for(@main)

    # No stale snapshot — User#effective_identity_prompt reads from the
    # static source instead.
    assert_nil trio.agent_configuration["identity_prompt"]
  end

  test "ensure_for clears any pre-existing cached identity_prompt" do
    trio = TrioSeeder.ensure_for(@main)
    trio.update!(agent_configuration: trio.agent_configuration.merge("identity_prompt" => "stale prompt"))

    TrioSeeder.ensure_for(@main)

    assert_nil trio.reload.agent_configuration["identity_prompt"]
  end

  test "trio has no stripe_customer" do
    trio = TrioSeeder.ensure_for(@main)

    assert_nil trio.stripe_customer
    assert_nil trio.billing_customer
  end

  test "trio does not create a TrusteeGrant" do
    assert_difference -> { TrusteeGrant.count }, 0 do
      TrioSeeder.ensure_for(@main)
    end
  end

  test "trio gets its own private workspace (used as memory)" do
    trio = TrioSeeder.ensure_for(@main)

    workspaces = @tenant.collectives.where(
      collective_type: "private_workspace",
      created_by_id: trio.id,
    )
    assert_equal 1, workspaces.count
  end

  test "ensure_for in two collectives in the same tenant creates separate trios" do
    other = create_collective(tenant: @tenant, created_by: @owner)

    trio_main = TrioSeeder.ensure_for(@main)
    trio_other = TrioSeeder.ensure_for(other)

    assert_not_equal trio_main.id, trio_other.id
    assert_equal trio_main.id, @main.reload.trio_user_id
    assert_equal trio_other.id, other.reload.trio_user_id
  end

  test "TrioSeeder is the only production source creating system_role: 'trio' users" do
    # Scans app/ for hash-literal assignments shaped like
    # `system_role: "trio",` — the form that appears inside User.create!(...).
    # Query usage (`.where(users: { system_role: "trio" })`) ends with `}`
    # instead of a comma and is intentionally not flagged.
    #
    # If this list ever contains another file, a new code path is creating
    # privileged system users — re-evaluate the security model before merging.
    sources = Dir.glob("app/**/*.rb").select do |file|
      File.read(file).match?(/system_role:\s*["']trio["']\s*,/)
    end

    assert_equal ["app/services/trio_seeder.rb"], sources.sort,
      "Expected TrioSeeder to be the sole creator of system_role: 'trio' users; " \
      "found additional sources: #{sources.inspect}"
  end
end
