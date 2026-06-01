require "test_helper"

# Tests for User#primary_user_list_in!(tenant) — the lazy-creation helper
# used by the "add to list" gesture. Primary lists are unique per (owner,
# tenant) and live in tenant.main_collective.
class UserPrimaryListTest < ActiveSupport::TestCase
  def setup
    # Build a tenant that has a main collective; @user is a member of both.
    @tenant = create_tenant(subdomain: "p-#{SecureRandom.hex(4)}")
    @user = create_user(email: "u-#{SecureRandom.hex(4)}@example.com", name: "U #{SecureRandom.hex(4)}")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: nil)
  end

  test "primary_user_list_in! creates a primary list in the tenant's main collective" do
    list = @user.primary_user_list_in!(@tenant)
    assert list.persisted?
    assert_equal @user, list.owner
    assert_equal @user, list.creator
    assert_equal @tenant.main_collective, list.collective
    assert list.is_primary
    assert_equal "public", list.visibility
  end

  test "primary_user_list_in! is idempotent" do
    first  = @user.primary_user_list_in!(@tenant)
    second = @user.primary_user_list_in!(@tenant)
    assert_equal first.id, second.id
  end

  test "primary_user_list_in! does not create a duplicate" do
    @user.primary_user_list_in!(@tenant)
    assert_no_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: true).count } do
      @user.primary_user_list_in!(@tenant)
    end
  end

  test "default name uses display_name when set" do
    @user.tenant_users.first.update!(display_name: "Sparkles")
    list = @user.primary_user_list_in!(@tenant)
    assert_equal "Sparkles's list", list.name
  end

  test "default name format ends with 's list" do
    list = @user.primary_user_list_in!(@tenant)
    assert list.name.end_with?("'s list")
  end

  test "idempotent lookup finds the primary even from a different collective thread scope" do
    @user.primary_user_list_in!(@tenant)

    # Scope thread to a different (non-main) collective in the same tenant.
    other = create_collective(tenant: @tenant, created_by: @user, name: "Other", handle: "o-#{SecureRandom.hex(4)}")
    other.add_user!(@user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: other.handle)

    # The second call should still find the existing primary (which lives in
    # main_collective) — not double-create. tenant_scoped_only bypasses the
    # default collective scope filter.
    second = @user.primary_user_list_in!(@tenant)
    assert_equal @tenant.main_collective.id, second.collective_id
    assert_equal 1, UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: true).count
  end

  test "two users in the same tenant each get their own primary" do
    other = create_user(email: "o-#{SecureRandom.hex(4)}@example.com", name: "O #{SecureRandom.hex(4)}")
    @tenant.add_user!(other)
    @tenant.main_collective.add_user!(other)

    a = @user.primary_user_list_in!(@tenant)
    b = other.primary_user_list_in!(@tenant)
    assert_not_equal a.id, b.id
  end

  test "same user in two tenants gets a separate primary in each" do
    list_a = @user.primary_user_list_in!(@tenant)

    other_tenant = create_tenant(subdomain: "p2-#{SecureRandom.hex(4)}")
    other_tenant.add_user!(@user)
    other_tenant.create_main_collective!(created_by: @user)
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: nil)

    list_b = @user.primary_user_list_in!(other_tenant)
    assert_not_equal list_a.id, list_b.id
    assert_equal @tenant.id,       list_a.tenant_id
    assert_equal other_tenant.id,  list_b.tenant_id
  end
end
