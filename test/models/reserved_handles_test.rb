require "test_helper"

class ReservedHandlesTest < ActiveSupport::TestCase
  test "group_tag? recognizes group tags case-insensitively" do
    assert ReservedHandles.group_tag?("everyone")
    assert ReservedHandles.group_tag?("Admins")
    assert_not ReservedHandles.group_tag?("trio")
    assert_not ReservedHandles.group_tag?("alice")
    assert_not ReservedHandles.group_tag?(nil)
  end

  test "role_tags and group_tags are derived from the capability role list" do
    # One pluralized tag per capability role, so new/custom roles reserve
    # automatically. Persona roles (trio) deliberately don't get a pluralized
    # group tag — their singular tag comes from AGENT_ROLES.
    expected = CollectiveMember.capability_roles.index_by(&:pluralize)
    assert_equal expected, ReservedHandles.role_tags
    # Every capability role's tag is a group tag, plus @everyone.
    assert ReservedHandles.group_tag?("representatives")
    assert ReservedHandles.group_tag?("summarizers")
    assert_not ReservedHandles.group_tag?("trios")
    assert_equal(["everyone"] + expected.keys, ReservedHandles.group_tags)
  end

  test "every agent tag maps to a valid persona role" do
    ReservedHandles::AGENT_ROLES.each_value do |persona_role|
      assert_includes CollectiveMember.valid_roles, persona_role
      assert_not_includes CollectiveMember.capability_roles, persona_role
    end
  end

  test "collective_local? covers group tags and agent handles" do
    assert ReservedHandles.collective_local?("representatives")
    assert ReservedHandles.collective_local?("everyone")
    assert ReservedHandles.collective_local?("admins")
    assert ReservedHandles.collective_local?("trio")
    assert_not ReservedHandles.collective_local?("alice")
  end

  test "required_system_role returns the agent role or nil" do
    assert_equal "trio", ReservedHandles.required_system_role("trio")
    assert_equal "trio", ReservedHandles.required_system_role("TRIO")
    assert_nil ReservedHandles.required_system_role("everyone")
    assert_nil ReservedHandles.required_system_role("alice")
  end

  test "forbidden_for_user? blocks group tags for everyone" do
    assert ReservedHandles.forbidden_for_user?("everyone", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("everyone", system_role: "trio")
    assert ReservedHandles.forbidden_for_user?("admins", system_role: "trio")
  end

  test "forbidden_for_user? gates agent handles on matching system_role" do
    assert ReservedHandles.forbidden_for_user?("trio", system_role: nil)
    assert ReservedHandles.forbidden_for_user?("trio", system_role: "something-else")
    assert_not ReservedHandles.forbidden_for_user?("trio", system_role: "trio")
  end

  test "forbidden_for_user? allows ordinary handles" do
    assert_not ReservedHandles.forbidden_for_user?("alice", system_role: nil)
  end

  test "forbidden_for_collective? blocks main and group tags but not agent handles" do
    assert ReservedHandles.forbidden_for_collective?("main")
    assert ReservedHandles.forbidden_for_collective?("everyone")
    assert ReservedHandles.forbidden_for_collective?("ADMINS")
    # Agent handles stay claimable as collective handles (backwards compatible).
    assert_not ReservedHandles.forbidden_for_collective?("trio")
    assert_not ReservedHandles.forbidden_for_collective?("alice")
  end
end
