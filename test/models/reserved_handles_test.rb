require "test_helper"

class ReservedHandlesTest < ActiveSupport::TestCase
  test "group_tag? recognizes group tags case-insensitively" do
    assert ReservedHandles.group_tag?("everyone")
    assert ReservedHandles.group_tag?("Admins")
    assert_not ReservedHandles.group_tag?("cadence")
    assert_not ReservedHandles.group_tag?("trio")
    assert_not ReservedHandles.group_tag?("alice")
    assert_not ReservedHandles.group_tag?(nil)
  end

  test "role_tags and group_tags are derived from the capability role list" do
    # One pluralized tag per capability role, so new/custom roles reserve
    # automatically. Persona roles (cadence, melody, counterpoint) and the
    # ensemble role (trio) deliberately don't get a pluralized group tag —
    # their singular tags come from AGENT_ROLES / ENSEMBLE_TAGS.
    expected = CollectiveMember.capability_roles.index_by(&:pluralize)
    assert_equal expected, ReservedHandles.role_tags
    # Every capability role's tag is a group tag, plus @everyone.
    assert ReservedHandles.group_tag?("representatives")
    assert ReservedHandles.group_tag?("summarizers")
    assert_not ReservedHandles.group_tag?("cadences")
    assert_not ReservedHandles.group_tag?("trios")
    assert_equal(["everyone"] + expected.keys, ReservedHandles.group_tags)
  end

  test "every agent tag maps to a valid persona role" do
    ReservedHandles::AGENT_ROLES.each_value do |persona_role|
      assert_includes CollectiveMember.valid_roles, persona_role
      assert_not_includes CollectiveMember.capability_roles, persona_role
    end
  end

  test "the ensemble tag maps to a valid ensemble role" do
    ReservedHandles::ENSEMBLE_TAGS.each_value do |ensemble_role|
      assert_includes CollectiveMember.valid_roles, ensemble_role
      assert_includes CollectiveMember.ensemble_roles, ensemble_role
      assert_not_includes CollectiveMember.capability_roles, ensemble_role
    end
  end

  test "collective_local? covers group tags, agent handles, and the ensemble tag" do
    assert ReservedHandles.collective_local?("representatives")
    assert ReservedHandles.collective_local?("everyone")
    assert ReservedHandles.collective_local?("admins")
    assert ReservedHandles.collective_local?("cadence")
    assert ReservedHandles.collective_local?("melody")
    assert ReservedHandles.collective_local?("counterpoint")
    assert ReservedHandles.collective_local?("trio")
    assert_not ReservedHandles.collective_local?("alice")
  end

  test "required_system_role returns the agent role or nil" do
    assert_equal "cadence", ReservedHandles.required_system_role("cadence")
    assert_equal "cadence", ReservedHandles.required_system_role("CADENCE")
    assert_equal "melody", ReservedHandles.required_system_role("melody")
    assert_nil ReservedHandles.required_system_role("everyone")
    assert_nil ReservedHandles.required_system_role("alice")
    # The ensemble tag names no single user — no system_role unlocks it.
    assert_nil ReservedHandles.required_system_role("trio")
  end

  test "forbidden_for_user? blocks group tags for everyone" do
    assert ReservedHandles.forbidden_for_user?("everyone", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("everyone", system_role: "cadence")
    assert ReservedHandles.forbidden_for_user?("admins", system_role: "cadence")
  end

  test "forbidden_for_user? gates agent handles on matching system_role" do
    assert ReservedHandles.forbidden_for_user?("cadence", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("cadence", system_role: "something-else")
    assert ReservedHandles.forbidden_for_user?("cadence", system_role: "melody")
    assert_not ReservedHandles.forbidden_for_user?("cadence", system_role: "cadence")
    assert_not ReservedHandles.forbidden_for_user?("melody", system_role: "melody")
  end

  test "forbidden_for_user? allows ordinary handles" do
    assert_not ReservedHandles.forbidden_for_user?("alice", system_role: nil)
  end

  test "forbidden_for_user? reserves persona handle prefixes for matching system agents" do
    assert ReservedHandles.forbidden_for_user?("cadence-engineering", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("CADENCE-Engineering", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("cadence-engineering", system_role: "something-else")
    assert_not ReservedHandles.forbidden_for_user?("cadence-engineering", system_role: "cadence")
    assert ReservedHandles.forbidden_for_user?("melody-engineering", system_role: nil)
    assert_not ReservedHandles.forbidden_for_user?("melody-engineering", system_role: "melody")
    # No dash, no reservation — only the prefix pattern is claimed.
    assert_not ReservedHandles.forbidden_for_user?("cadencefan", system_role: nil)
  end

  test "the ensemble namespace is reserved for everyone, system agents included" do
    assert ReservedHandles.ensemble_reserved?("trio")
    assert ReservedHandles.ensemble_reserved?("TRIO")
    assert ReservedHandles.ensemble_reserved?("trio-engineering")
    assert_not ReservedHandles.ensemble_reserved?("triofan")

    assert ReservedHandles.forbidden_for_user?("trio", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("trio", system_role: "cadence")
    assert ReservedHandles.forbidden_for_user?("trio-engineering", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("trio-engineering", system_role: "cadence")
    assert_not ReservedHandles.forbidden_for_user?("triofan", system_role: nil)
  end

  test "forbidden_for_collective? blocks main, group tags, and the agent and ensemble namespaces" do
    assert ReservedHandles.forbidden_for_collective?("main")
    assert ReservedHandles.forbidden_for_collective?("everyone")
    assert ReservedHandles.forbidden_for_collective?("ADMINS")
    # The agent namespace — exact tags and their prefixes — is reserved
    # unconditionally: identity users mirror collective handles, and no user
    # but the matching system agent may hold cadence/cadence-*.
    assert ReservedHandles.forbidden_for_collective?("cadence")
    assert ReservedHandles.forbidden_for_collective?("cadence-fans")
    assert ReservedHandles.forbidden_for_collective?("melody")
    assert ReservedHandles.forbidden_for_collective?("counterpoint-club")
    # The ensemble namespace is reserved the same way.
    assert ReservedHandles.forbidden_for_collective?("trio")
    assert ReservedHandles.forbidden_for_collective?("trio-fans")
    assert_not ReservedHandles.forbidden_for_collective?("cadencefan")
    assert_not ReservedHandles.forbidden_for_collective?("triofan")
    assert_not ReservedHandles.forbidden_for_collective?("alice")
  end
end
