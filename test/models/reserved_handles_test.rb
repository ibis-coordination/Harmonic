require "test_helper"

class ReservedHandlesTest < ActiveSupport::TestCase
  test "group_tag? recognizes group tags case-insensitively" do
    assert ReservedHandles.group_tag?("everyone")
    assert ReservedHandles.group_tag?("Admins")
    assert_not ReservedHandles.group_tag?("trio")
    assert_not ReservedHandles.group_tag?("alice")
    assert_not ReservedHandles.group_tag?(nil)
  end

  test "collective_local? covers group tags and agent handles" do
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
