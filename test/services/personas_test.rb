# typed: false

require "test_helper"

class PersonasTest < ActiveSupport::TestCase
  test "registry holds the three built-in personas" do
    assert_equal ["melody", "counterpoint", "cadence"], Personas.system_roles
  end

  test "the ensemble names the set" do
    assert_equal "Trio", Personas::ENSEMBLE_NAME
    assert_equal "trio", Personas::ENSEMBLE_ROLE
    assert_includes CollectiveMember.ensemble_roles, Personas::ENSEMBLE_ROLE
  end

  test "fetch returns the definition for a system role and nil otherwise" do
    assert_equal "Melody", Personas.fetch("melody").name
    assert_equal "Counterpoint", Personas.fetch("counterpoint").name
    assert_equal "Cadence", Personas.fetch("cadence").name
    assert_nil Personas.fetch("nonsense")
    assert_nil Personas.fetch(nil)
  end

  test "each persona holds a grantable capability role" do
    assert_equal "automator", Personas.fetch("melody").capability_role
    assert_equal "moderator", Personas.fetch("counterpoint").capability_role
    assert_equal "summarizer", Personas.fetch("cadence").capability_role

    Personas.all.each do |persona|
      assert_includes CollectiveMember.capability_roles, persona.capability_role
    end
  end

  test "each persona has a non-blank system prompt read from its markdown source" do
    Personas.all.each do |persona|
      assert persona.prompt.present?, "#{persona.system_role} prompt is blank"
      assert_includes persona.prompt, persona.name
    end
  end

  test "each persona names a default-model env var" do
    assert_equal "MELODY_DEFAULT_MODEL", Personas.fetch("melody").default_model_env
    assert_equal "COUNTERPOINT_DEFAULT_MODEL", Personas.fetch("counterpoint").default_model_env
    assert_equal "CADENCE_DEFAULT_MODEL", Personas.fetch("cadence").default_model_env
  end

  test "default_model reads the persona's env var" do
    persona = Personas.fetch("melody")
    original = ENV.fetch("MELODY_DEFAULT_MODEL", nil)
    ENV["MELODY_DEFAULT_MODEL"] = "openai/gpt-5.2"
    assert_equal "openai/gpt-5.2", persona.default_model
    ENV["MELODY_DEFAULT_MODEL"] = ""
    assert_nil persona.default_model
  ensure
    ENV["MELODY_DEFAULT_MODEL"] = original
  end

  test "each persona ships at least a mention responder automation" do
    Personas.all.each do |persona|
      mention_rules = persona.default_automations.select do |attrs|
        Array(attrs[:event_types] || attrs[:event_type]).include?("comment.created")
      end
      assert mention_rules.any?, "#{persona.system_role} has no mention responder"
      assert_equal "self_or_reply", mention_rules.first[:mention_filter]
    end
  end

  test "every persona ships the same single default automation — none is special" do
    Personas.all.each do |persona|
      assert_equal 1, persona.default_automations.size,
        "#{persona.system_role} should ship exactly the mention responder"
    end
  end

  # The identity constants that gate handles, validation, and mention
  # resolution are literal lists in their own homes; this pins them to the
  # registry so a new persona can't be half-added.
  test "registry agrees with SYSTEM_ROLES, AGENT_ROLES, persona_roles, and the ensemble" do
    assert_equal Personas.system_roles.sort, User::SYSTEM_ROLES.sort
    assert_equal Personas.system_roles.sort, ReservedHandles::AGENT_ROLES.keys.sort
    assert_equal Personas.system_roles.sort, ReservedHandles::AGENT_ROLES.values.sort
    assert_equal Personas.system_roles.sort, CollectiveMember.persona_roles.sort
    assert_equal Personas.system_roles.sort, TenantUser.persona_roles.sort
    assert_equal [Personas::ENSEMBLE_ROLE], ReservedHandles::ENSEMBLE_TAGS.keys
    assert_equal [Personas::ENSEMBLE_ROLE], ReservedHandles::ENSEMBLE_TAGS.values
    assert_equal [Personas::ENSEMBLE_ROLE], CollectiveMember.ensemble_roles
  end
end
