require "test_helper"

class UserListTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def make_user(name_suffix = SecureRandom.hex(4))
    user = create_user(email: "u-#{name_suffix}@example.com", name: "U #{name_suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  # ---- Creation ----

  test "create with required fields succeeds" do
    list = UserList.create!(creator: @user, owner: @user, name: "Friends")

    assert list.persisted?
    assert_equal @user, list.creator
    assert_equal @user, list.owner
    assert_equal @tenant.id, list.tenant_id
    assert_equal @collective.id, list.collective_id
    assert_equal "public", list.visibility
    assert_equal false, list.is_primary
  end

  test "truncated_id is the first 8 hex chars of id (Postgres-generated)" do
    list = UserList.create!(creator: @user, owner: @user, name: "X")
    assert_equal list.id.to_s[0..7], list.truncated_id
    assert_equal 8, list.truncated_id.length
  end

  test "tenant_id and collective_id auto-set from thread scope" do
    list = UserList.create!(creator: @user, owner: @user, name: "Auto Scope")
    assert_equal @tenant.id, list.tenant_id
    assert_equal @collective.id, list.collective_id
  end

  # ---- Name / description ----

  test "name presence required" do
    list = UserList.new(creator: @user, owner: @user, name: nil)
    assert_not list.valid?
    assert_includes list.errors[:name], "can't be blank"
  end

  test "name length capped at 80" do
    list = UserList.new(creator: @user, owner: @user, name: "a" * 81)
    assert_not list.valid?
  end

  test "description optional and capped at 500" do
    UserList.create!(creator: @user, owner: @user, name: "X", description: nil)
    too_long = UserList.new(creator: @user, owner: @user, name: "X", description: "a" * 501)
    assert_not too_long.valid?
  end

  # ---- primary list immutability ----

  test "primary list rejects name changes after creation" do
    list = UserList.create!(creator: @user, owner: @user, name: "original", is_primary: true)
    list.name = "renamed"
    assert_not list.valid?
    assert_predicate list.errors[:name], :any?
  end

  test "primary list rejects description changes after creation" do
    list = UserList.create!(creator: @user, owner: @user, name: "tuned in", description: nil, is_primary: true)
    list.description = "new description"
    assert_not list.valid?
    assert_predicate list.errors[:description], :any?
  end

  test "primary list rejects add_policy changes after creation" do
    list = UserList.create!(creator: @user, owner: @user, name: "tuned in", is_primary: true)
    list.add_policy = "members_add"
    assert_not list.valid?
    assert_predicate list.errors[:add_policy], :any?
  end

  test "non-primary list permits all attribute changes" do
    list = UserList.create!(creator: @user, owner: @user, name: "Custom", description: "x")
    list.name = "Renamed"
    list.description = "y"
    list.add_policy = "self_add"
    list.visibility = "public"
    assert list.valid?
  end

  # ---- display_name ----

  test "display_name returns 'tuned in' for a primary list regardless of stored name" do
    list = UserList.create!(creator: @user, owner: @user, name: "Legacy Name", is_primary: true)
    assert_equal "tuned in", list.display_name
  end

  test "display_name returns the stored name for a non-primary list" do
    list = UserList.create!(creator: @user, owner: @user, name: "Friends", is_primary: false)
    assert_equal "Friends", list.display_name
  end

  # ---- visibility ----

  test "visibility must be public or private" do
    list = UserList.new(creator: @user, owner: @user, name: "X", visibility: "secret")
    assert_not list.valid?
  end

  test "public? / private? helpers" do
    pub  = UserList.create!(creator: @user, owner: @user, name: "P", visibility: "public")
    priv = UserList.create!(creator: @user, owner: @user, name: "Q", visibility: "private")
    assert pub.public?
    assert priv.private?
    assert_not pub.private?
    assert_not priv.public?
  end

  # ---- is_primary uniqueness (per (owner, tenant)) ----

  test "a user can have one primary list per tenant" do
    UserList.create!(creator: @user, owner: @user, name: "A", is_primary: true)

    second = UserList.new(creator: @user, owner: @user, name: "B", is_primary: true)
    assert_not second.valid?
    assert_includes second.errors[:is_primary].join(" "), "primary"
  end

  test "soft-deleted primary list does not block creating a new primary" do
    first = UserList.create!(creator: @user, owner: @user, name: "A", is_primary: true)
    first.soft_delete!(by: @user)

    second = UserList.create!(creator: @user, owner: @user, name: "B", is_primary: true)
    assert second.persisted?
    assert second.is_primary
  end

  test "two different owners can each have their own primary list in the same tenant" do
    other = make_user
    UserList.create!(creator: @user, owner: @user, name: "Mine", is_primary: true)
    theirs = UserList.create!(creator: other, owner: other, name: "Theirs", is_primary: true)
    assert theirs.persisted?
  end

  test "primary uniqueness spans collectives — a user with a primary in main can't add another primary in a non-main collective" do
    # Build a real tenant with a main_collective; @user's primary lives there.
    t = create_tenant(subdomain: "pu-#{SecureRandom.hex(4)}")
    u = create_user(email: "pu-#{SecureRandom.hex(4)}@example.com", name: "PU #{SecureRandom.hex(4)}")
    t.add_user!(u)
    t.create_main_collective!(created_by: u)
    other_coll = create_collective(tenant: t, created_by: u, name: "Other", handle: "o-#{SecureRandom.hex(4)}")
    other_coll.add_user!(u)

    UserList.create!(creator: u, owner: u, tenant: t, collective: t.main_collective,
                     name: "A", is_primary: true)

    # Even though it's a different collective, it's the same tenant — should be rejected.
    second = UserList.new(creator: u, owner: u, tenant: t, collective: other_coll,
                          name: "B", is_primary: true)
    assert_not second.valid?
    assert_includes second.errors[:is_primary].join(" "), "primary"
  end

  test "non-primary lists are unrestricted in count" do
    3.times do |i|
      UserList.create!(creator: @user, owner: @user, name: "L#{i}", is_primary: false)
    end
    assert_equal 3, UserList.where(owner_id: @user.id, is_primary: false).count
  end

  # ---- visible_to? ----

  test "visible_to? — owner sees public and private" do
    pub  = UserList.create!(creator: @user, owner: @user, name: "P", visibility: "public")
    priv = UserList.create!(creator: @user, owner: @user, name: "Q", visibility: "private")
    assert pub.visible_to?(@user)
    assert priv.visible_to?(@user)
  end

  test "visible_to? — collective member sees public, not private" do
    other = make_user
    pub  = UserList.create!(creator: @user, owner: @user, name: "P", visibility: "public")
    priv = UserList.create!(creator: @user, owner: @user, name: "Q", visibility: "private")
    assert pub.visible_to?(other)
    assert_not priv.visible_to?(other)
  end

  test "visible_to? — non-collective-member cannot see anything" do
    stranger = create_user(email: "s-#{SecureRandom.hex(4)}@example.com", name: "Stranger #{SecureRandom.hex(4)}")
    @tenant.add_user!(stranger)
    pub = UserList.create!(creator: @user, owner: @user, name: "P", visibility: "public")
    assert_not pub.visible_to?(stranger)
  end

  test "visible_to? — nil user cannot see anything" do
    pub = UserList.create!(creator: @user, owner: @user, name: "P", visibility: "public")
    assert_not pub.visible_to?(nil)
  end

  # ---- path ----

  test "path for a list in the main collective is /lists/:truncated_id" do
    # Setup: create a tenant with main_collective and a list in it.
    main_tenant = create_tenant(subdomain: "m-#{SecureRandom.hex(4)}")
    main_user = create_user(email: "mo-#{SecureRandom.hex(4)}@example.com", name: "M #{SecureRandom.hex(4)}")
    main_tenant.add_user!(main_user)
    main_tenant.create_main_collective!(created_by: main_user)
    main_collective = main_tenant.main_collective
    Collective.scope_thread_to_collective(subdomain: main_tenant.subdomain, handle: nil)

    list = UserList.create!(creator: main_user, owner: main_user, name: "X",
                            tenant: main_tenant, collective: main_collective)

    assert_equal "/lists/#{list.truncated_id}", list.path
  end

  test "path for a list in a non-main collective is /collectives/:handle/lists/:truncated_id" do
    # @collective from create_tenant_collective_user is NOT a main collective.
    list = UserList.create!(creator: @user, owner: @user, name: "X")
    assert_equal "/collectives/#{@collective.handle}/lists/#{list.truncated_id}", list.path
  end

  # ---- attr_readonly ----

  test "tenant_id immutable after create" do
    list = UserList.create!(creator: @user, owner: @user, name: "X")
    other_tenant = create_tenant(subdomain: "o-#{SecureRandom.hex(4)}")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { list.update!(tenant_id: other_tenant.id) }
  end

  test "collective_id immutable after create" do
    list = UserList.create!(creator: @user, owner: @user, name: "X")
    other = create_collective(tenant: @tenant, created_by: @user, name: "O", handle: "o-#{SecureRandom.hex(4)}")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { list.update!(collective_id: other.id) }
  end

  test "creator_id immutable after create" do
    list = UserList.create!(creator: @user, owner: @user, name: "X")
    other = make_user
    assert_raises(ActiveRecord::ReadonlyAttributeError) { list.update!(creator_id: other.id) }
  end

  test "owner_id IS mutable for non-primary lists" do
    list = UserList.create!(creator: @user, owner: @user, name: "X")
    other = make_user
    list.update!(owner_id: other.id)
    assert_equal other.id, list.reload.owner_id
    assert_equal @user.id, list.reload.creator_id # creator unchanged
  end

  test "owner_id is immutable for a primary list — cannot be transferred" do
    list = UserList.create!(creator: @user, owner: @user, name: "Mine", is_primary: true)
    other = make_user
    list.owner_id = other.id
    assert_not list.valid?
    assert_includes list.errors[:owner_id].join(" "), "primary"
  end

  test "is_primary is immutable for a primary list — cannot be demoted" do
    list = UserList.create!(creator: @user, owner: @user, name: "Mine", is_primary: true)
    list.is_primary = false
    assert_not list.valid?
    assert_includes list.errors[:is_primary].join(" "), "cannot be changed"
  end

  test "is_primary is immutable for a non-primary list — cannot be promoted" do
    list = UserList.create!(creator: @user, owner: @user, name: "Custom")  # is_primary defaults false
    list.is_primary = true
    assert_not list.valid?
    assert_includes list.errors[:is_primary].join(" "), "cannot be changed"
  end

  # ---- Soft delete ----

  test "soft_delete! sets deleted_at and excludes from default scope" do
    list = UserList.create!(creator: @user, owner: @user, name: "Goner")
    list.soft_delete!(by: @user)
    assert list.deleted?
    assert_nil UserList.find_by(id: list.id)
    assert_not_nil UserList.with_deleted.find_by(id: list.id)
  end

  # ---- Non-human owners ----

  test "ai_agent user can own a list" do
    agent = create_ai_agent(parent: @user)
    @collective.add_user!(agent)
    list = UserList.create!(creator: agent, owner: agent, name: "Agent List")
    assert list.persisted?
  end

  test "collective_identity user can own a list" do
    identity = create_user(
      email: "ci-#{SecureRandom.hex(4)}@example.com",
      name: "CI #{SecureRandom.hex(4)}",
      user_type: "collective_identity"
    )
    @tenant.add_user!(identity)
    @collective.add_user!(identity)
    list = UserList.create!(creator: identity, owner: identity, name: "CI List")
    assert list.persisted?
  end

  # ---- DB-level partial unique index ----

  test "partial unique index catches a duplicate primary even when the validation is bypassed" do
    UserList.create!(creator: @user, owner: @user, name: "A", is_primary: true)

    dup = UserList.new(creator: @user, owner: @user, name: "B", is_primary: true)
    # `save(validate: false)` skips one_primary_per_owner_per_tenant so we
    # exercise the DB-level partial unique index directly.
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save(validate: false) }
  end

  # ---- restrict_with_exception on User deletion ----

  test "cannot destroy a user who owns lists (restrict_with_exception)" do
    other = make_user
    UserList.create!(creator: other, owner: other, name: "Theirs")
    assert_raises(ActiveRecord::DeleteRestrictionError) { other.destroy! }
  end

  test "cannot destroy a user who created lists (even if owner has changed)" do
    creator_user = make_user
    new_owner    = make_user
    list = UserList.create!(creator: creator_user, owner: creator_user, name: "L")
    list.update!(owner_id: new_owner.id)

    assert_raises(ActiveRecord::DeleteRestrictionError) { creator_user.destroy! }
  end

  # ---- Tenant isolation ----

  test "tenant scoping isolates lists" do
    UserList.create!(creator: @user, owner: @user, name: "Mine")
    other_tenant = create_tenant(subdomain: "ot-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    Collective.clear_thread_scope
    assert_equal 0, UserList.unscope(where: :collective_id).count
  end

  # ---- content_snapshot ----

  test "content_snapshot combines name and description" do
    list = UserList.create!(creator: @user, owner: @user, name: "Title", description: "Body text")
    assert_includes list.content_snapshot, "Title"
    assert_includes list.content_snapshot, "Body text"
  end

  # ---- User#primary_user_list_in! race safety ----

  test "primary_user_list_in! recovers when a concurrent create wins the race" do
    list1 = @user.primary_user_list_in!(@tenant)

    # Force the SELECT-then-CREATE path to take the create branch despite
    # list1 existing. The create attempt will trip the primary-uniqueness
    # validation; the rescue should re-query and return list1.
    original = UserList.method(:tenant_scoped_only)
    remaining = 1
    UserList.singleton_class.define_method(:tenant_scoped_only) do |*args|
      if remaining.positive?
        remaining -= 1
        UserList.where(id: nil) # pretend no primary list exists
      else
        original.call(*args)
      end
    end

    begin
      list2 = @user.primary_user_list_in!(@tenant)
      assert_equal list1.id, list2.id, "expected to recover existing list after concurrent-create race"
    ensure
      UserList.singleton_class.send(:remove_method, :tenant_scoped_only)
    end
  end
end
