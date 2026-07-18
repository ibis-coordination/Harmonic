# typed: false

require "test_helper"

class PersonaSeederTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant(subdomain: "persona-seeder-#{SecureRandom.hex(4)}")
    @owner = create_user(email: "owner_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@owner)
    @tenant.create_main_collective!(created_by: @owner)
    @main = T.must(@tenant.main_collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  teardown do
    Tenant.clear_thread_scope
  end

  test "ensure_for creates a persona user when none exists" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert cadence.persisted?
    assert_equal "ai_agent", cadence.user_type
    assert_equal "cadence", cadence.system_role
    assert_equal "Cadence", cadence.name
  end

  test "each persona seeds its own user with its own identity" do
    melody = PersonaSeeder.ensure_for(@main, Personas::MELODY)
    counterpoint = PersonaSeeder.ensure_for(@main, Personas::COUNTERPOINT)
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert_equal ["melody", "counterpoint", "cadence"],
                 [melody, counterpoint, cadence].map(&:system_role)
    assert_equal ["Melody", "Counterpoint", "Cadence"],
                 [melody, counterpoint, cadence].map(&:name)
    assert_equal 3, [melody, counterpoint, cadence].map(&:id).uniq.size
  end

  test "a persona's principal is the collective's identity user" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert_equal @main.identity_user_id, cadence.parent_id
  end

  test "each collective's persona is principaled by that collective's own identity" do
    other = create_collective(tenant: @tenant, created_by: @owner)

    cadence_main = PersonaSeeder.ensure_for(@main, Personas::CADENCE)
    cadence_other = PersonaSeeder.ensure_for(other, Personas::CADENCE)

    assert_equal @main.identity_user_id, cadence_main.parent_id
    assert_equal other.identity_user_id, cadence_other.parent_id
    assert_not_equal cadence_main.parent_id, cadence_other.parent_id
  end

  test "ensure_for is idempotent per persona" do
    first = PersonaSeeder.ensure_for(@main, Personas::CADENCE)
    second = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert_equal first.id, second.id
  end

  test "ensure_for seeds the persona without activating it" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    # Activation state (the roles) is PersonaActivator's job.
    assert_equal cadence.id, @main.reload.seeded_persona_user("cadence")&.id
    assert_nil @main.persona_user("cadence")
  end

  test "a persona is a CollectiveMember of its collective" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert @main.user_is_member?(cadence)
  end

  test "persona handles follow tag-[collective_handle] for every collective" do
    other = create_collective(tenant: @tenant, created_by: @owner, handle: "garden-#{SecureRandom.hex(2)}")

    main_cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)
    other_melody = PersonaSeeder.ensure_for(other, Personas::MELODY)

    assert_equal "cadence-#{@main.handle}", main_cadence.tenant_users.find_by(tenant_id: @tenant.id).handle
    assert_equal "melody-#{other.handle}", other_melody.tenant_users.find_by(tenant_id: @tenant.id).handle
  end

  test "a squatted persona handle falls back to a suffixed one" do
    other = create_collective(tenant: @tenant, created_by: @owner, handle: "sqd-#{SecureRandom.hex(2)}")
    squatter = create_user(email: "sq_#{SecureRandom.hex(4)}@example.com")
    squatter_tu = @tenant.add_user!(squatter)
    # Bypass validation the way a legacy row would exist: claimed before the
    # prefix was reserved.
    squatter_tu.update_column(:handle, "cadence-#{other.handle}")

    cadence = PersonaSeeder.ensure_for(other, Personas::CADENCE)
    handle = cadence.tenant_users.find_by(tenant_id: @tenant.id).handle

    assert_match(/\Acadence-#{Regexp.escape(other.handle)}-[a-f0-9]+\z/, handle)
  end

  test "personas are configured as internal ai_agents" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert cadence.internal_ai_agent?
    assert_equal "internal", cadence.agent_configuration["mode"]
  end

  test "a persona is seeded with the model from its default-model env var" do
    previous = ENV.fetch("CADENCE_DEFAULT_MODEL", nil)
    ENV["CADENCE_DEFAULT_MODEL"] = "trinity-large-thinking-free"

    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert_equal "trinity-large-thinking-free", cadence.agent_configuration["model"]
  ensure
    ENV["CADENCE_DEFAULT_MODEL"] = previous
  end

  test "a persona omits the model key when its default-model env var is unset" do
    previous = ENV.fetch("CADENCE_DEFAULT_MODEL", nil)
    ENV.delete("CADENCE_DEFAULT_MODEL")

    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert_not cadence.agent_configuration.key?("model"),
               "expected model key absent so the agent-runner falls back to its default model alias"
  ensure
    ENV["CADENCE_DEFAULT_MODEL"] = previous
  end

  test "personas resolve their identity prompts from their static sources" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)
    melody = PersonaSeeder.ensure_for(@main, Personas::MELODY)

    assert_equal Personas.fetch("cadence").prompt, cadence.effective_identity_prompt
    assert_equal Personas.fetch("melody").prompt, melody.effective_identity_prompt
  end

  test "a persona's agent_configuration does not cache identity_prompt" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    # No stale snapshot — User#effective_identity_prompt reads from the
    # static source instead.
    assert_nil cadence.agent_configuration["identity_prompt"]
  end

  test "ensure_for clears any pre-existing cached identity_prompt" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)
    cadence.update!(agent_configuration: cadence.agent_configuration.merge("identity_prompt" => "stale prompt"))

    PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert_nil cadence.reload.agent_configuration["identity_prompt"]
  end

  test "personas have no stripe_customer" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    assert_nil cadence.stripe_customer
    assert_nil cadence.billing_customer
  end

  test "personas do not create a TrusteeGrant" do
    assert_difference -> { TrusteeGrant.count }, 0 do
      PersonaSeeder.ensure_for(@main, Personas::CADENCE)
    end
  end

  test "a persona gets its own private workspace (used as memory)" do
    cadence = PersonaSeeder.ensure_for(@main, Personas::CADENCE)

    workspaces = @tenant.collectives.where(
      collective_type: "private_workspace",
      created_by_id: cadence.id,
    )
    assert_equal 1, workspaces.count
  end

  test "ensure_for in two collectives in the same tenant creates separate personas" do
    other = create_collective(tenant: @tenant, created_by: @owner)

    cadence_main = PersonaSeeder.ensure_for(@main, Personas::CADENCE)
    cadence_other = PersonaSeeder.ensure_for(other, Personas::CADENCE)

    assert_not_equal cadence_main.id, cadence_other.id
    assert_equal cadence_main.id, @main.reload.seeded_persona_user("cadence")&.id
    assert_equal cadence_other.id, other.reload.seeded_persona_user("cadence")&.id
  end

  test "PersonaSeeder is the only production source creating system_role users" do
    # Scans app/ for hash-literal assignments shaped like
    # `system_role: <value>,` — the form that appears inside User.create!(...).
    # Query usage (`.where(users: { system_role: role })`) ends with `}`
    # instead of a comma and is intentionally not flagged.
    #
    # If this list ever contains another file, a new code path is creating
    # privileged system users — re-evaluate the security model before merging.
    sources = Dir.glob("app/**/*.rb").select do |file|
      File.read(file).match?(/system_role:\s*[^,}\n]+,/)
    end

    # personas.rb is the persona data registry — its `system_role:` keys are
    # Definition struct fields, not User.create! calls.
    assert_equal ["app/services/persona_seeder.rb", "app/services/personas.rb"], sources.sort,
                 "Expected PersonaSeeder to be the sole creator of system_role users; " \
                 "found additional sources: #{sources.inspect}"
  end
end
