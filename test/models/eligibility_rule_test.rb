require "test_helper"

class EligibilityRuleTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def make_user(suffix = SecureRandom.hex(4))
    user = create_user(email: "u-#{suffix}@example.com", name: "U #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def outsider
    create_user(email: "out-#{SecureRandom.hex(4)}@example.com", name: "Outsider")
  end

  def rule(hash)
    EligibilityRule.parse(hash)
  end

  # ---- default ----

  test "default is a single open clause" do
    assert_equal({ "any_of" => [{ "type" => "open" }] }, EligibilityRule.default.to_h)
  end

  test "default matches any user and reports no errors" do
    assert EligibilityRule.default.matches?(@user, collective: @collective)
    assert_empty EligibilityRule.default.validation_errors(collective: @collective)
  end

  # ---- clause matching ----

  test "open matches any user" do
    r = rule({ "any_of" => [{ "type" => "open" }] })
    assert r.matches?(@user, collective: @collective)
    assert r.matches?(outsider, collective: @collective)
  end

  test "nil user never matches, even under open" do
    r = rule({ "any_of" => [{ "type" => "open" }] })
    assert_not r.matches?(nil, collective: @collective)
  end

  test "members matches collective members and not outsiders" do
    r = rule({ "any_of" => [{ "type" => "members" }] })
    assert r.matches?(@user, collective: @collective)
    assert_not r.matches?(outsider, collective: @collective)
  end

  test "members matches the collective identity user" do
    identity = @collective.identity_user
    skip "collective has no identity user" if identity.nil?
    r = rule({ "any_of" => [{ "type" => "members" }] })
    assert r.matches?(identity, collective: @collective)
  end

  test "role matches only members holding the role" do
    holder = make_user
    @collective.collective_members.find_by(user: holder).add_role!("summarizer")
    r = rule({ "any_of" => [{ "type" => "role", "role" => "summarizer" }] })

    assert r.matches?(holder, collective: @collective)
    assert_not r.matches?(@user, collective: @collective)
    assert_not r.matches?(outsider, collective: @collective)
  end

  test "users matches ids in the array" do
    alice = make_user("alice")
    bob = make_user("bob")
    r = rule({ "any_of" => [{ "type" => "users", "user_ids" => [alice.id, bob.id] }] })

    assert r.matches?(alice, collective: @collective)
    assert r.matches?(bob, collective: @collective)
    assert_not r.matches?(@user, collective: @collective)
  end

  test "list matches members of the list" do
    member = make_user
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    UserListMember.create!(user_list: list, user: member, added_by: @user)
    r = rule({ "any_of" => [{ "type" => "list", "list_id" => list.id }] })

    assert r.matches?(member, collective: @collective)
    assert_not r.matches?(@user, collective: @collective)
  end

  # ---- dangling references ----

  test "a deleted list matches nobody but leaves other clauses working" do
    member = make_user
    alice = make_user("alice")
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    UserListMember.create!(user_list: list, user: member, added_by: @user)
    r = rule({ "any_of" => [
      { "type" => "list", "list_id" => list.id },
      { "type" => "users", "user_ids" => [alice.id] },
    ] })
    list.soft_delete!(by: @user)

    assert_not r.matches?(member, collective: @collective)
    assert r.matches?(alice, collective: @collective)
  end

  test "a list_id that does not resolve matches nobody" do
    r = rule({ "any_of" => [{ "type" => "list", "list_id" => SecureRandom.uuid }] })
    assert_not r.matches?(@user, collective: @collective)
  end

  test "a user_id that does not resolve matches nobody" do
    r = rule({ "any_of" => [{ "type" => "users", "user_ids" => [SecureRandom.uuid] }] })
    assert_not r.matches?(@user, collective: @collective)
  end

  # ---- unions ----

  test "two-clause union matches a user satisfying either clause" do
    alice = make_user("alice")
    holder = make_user
    @collective.collective_members.find_by(user: holder).add_role!("admin")
    r = rule({ "any_of" => [
      { "type" => "users", "user_ids" => [alice.id] },
      { "type" => "role", "role" => "admin" },
    ] })

    assert r.matches?(alice, collective: @collective)
    assert r.matches?(holder, collective: @collective)
    assert_not r.matches?(make_user, collective: @collective)
  end

  test "three-clause union matches across users, role, and list" do
    alice = make_user("alice")
    holder = make_user
    listed = make_user
    @collective.collective_members.find_by(user: holder).add_role!("admin")
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    UserListMember.create!(user_list: list, user: listed, added_by: @user)
    r = rule({ "any_of" => [
      { "type" => "users", "user_ids" => [alice.id] },
      { "type" => "role", "role" => "admin" },
      { "type" => "list", "list_id" => list.id },
    ] })

    assert r.matches?(alice, collective: @collective)
    assert r.matches?(holder, collective: @collective)
    assert r.matches?(listed, collective: @collective)
    assert_not r.matches?(make_user, collective: @collective)
  end

  # ---- validation ----

  test "empty any_of is invalid" do
    errors = rule({ "any_of" => [] }).validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/at least one/i) })
  end

  test "more than ten clauses is invalid" do
    clauses = Array.new(11) { { "type" => "users", "user_ids" => [@user.id] } }
    errors = rule({ "any_of" => clauses }).validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/at most 10/i) })
  end

  test "open beside another clause is invalid" do
    errors = rule({ "any_of" => [
      { "type" => "open" },
      { "type" => "users", "user_ids" => [@user.id] },
    ] }).validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/only clause/i) })
  end

  test "members beside another clause is invalid" do
    errors = rule({ "any_of" => [
      { "type" => "members" },
      { "type" => "users", "user_ids" => [@user.id] },
    ] }).validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/only clause/i) })
  end

  test "unknown clause type is invalid" do
    errors = rule({ "any_of" => [{ "type" => "everyone" }] }).validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/unknown clause type/i) })
  end

  test "unknown role is invalid" do
    errors = rule({ "any_of" => [{ "type" => "role", "role" => "wizard" }] })
      .validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/role/i) })
  end

  test "a list from another collective is invalid" do
    other_collective = create_collective(tenant: @tenant, created_by: @user,
                                         name: "Other", handle: "other-collective")
    other_collective.add_user!(@user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: other_collective.handle)
    foreign = UserList.create!(creator: @user, owner: @user, name: "Theirs")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    errors = rule({ "any_of" => [{ "type" => "list", "list_id" => foreign.id }] })
      .validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/list/i) })
  end

  test "a private list is invalid as an electorate" do
    private_list = UserList.create!(creator: @user, owner: @user, name: "Secret",
                                    visibility: "private", add_policy: "owner_only")
    errors = rule({ "any_of" => [{ "type" => "list", "list_id" => private_list.id }] })
      .validation_errors(collective: @collective)

    assert(errors.any? { |e| e.match?(/public/i) })
  end

  test "a list turned private after the fact matches nobody" do
    member = make_user
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    UserListMember.create!(user_list: list, user: member, added_by: @user)
    r = rule({ "any_of" => [{ "type" => "list", "list_id" => list.id }] })
    assert r.matches?(member, collective: @collective)

    list.update!(visibility: "private", add_policy: "owner_only")

    assert_not r.matches?(member, collective: @collective),
               "a private list must not govern a decision whose voters are published by name"
  end

  test "a user who is not a collective member is invalid" do
    errors = rule({ "any_of" => [{ "type" => "users", "user_ids" => [outsider.id] }] })
      .validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/member/i) })
  end

  test "empty user_ids is invalid" do
    errors = rule({ "any_of" => [{ "type" => "users", "user_ids" => [] }] })
      .validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/at least one user/i) })
  end

  test "more than 200 user_ids is invalid" do
    ids = Array.new(201) { SecureRandom.uuid }
    errors = rule({ "any_of" => [{ "type" => "users", "user_ids" => ids }] })
      .validation_errors(collective: @collective)
    assert(errors.any? { |e| e.match?(/at most 200/i) })
  end

  test "duplicate user_ids are deduped on parse" do
    alice = make_user("alice")
    r = rule({ "any_of" => [{ "type" => "users", "user_ids" => [alice.id, alice.id] }] })
    assert_equal [alice.id], r.to_h["any_of"].first["user_ids"]
  end

  test "a valid rule reports no errors" do
    alice = make_user("alice")
    r = rule({ "any_of" => [{ "type" => "users", "user_ids" => [alice.id] }] })
    assert_empty r.validation_errors(collective: @collective)
  end

  # ---- structural parse failures ----

  test "parse raises on a non-hash, non-string value" do
    assert_raises(EligibilityRule::ParseError) { EligibilityRule.parse(42) }
  end

  test "parse raises when any_of is missing" do
    assert_raises(EligibilityRule::ParseError) { EligibilityRule.parse({ "type" => "open" }) }
  end

  test "parse raises when any_of is not an array" do
    assert_raises(EligibilityRule::ParseError) { EligibilityRule.parse({ "any_of" => "open" }) }
  end

  test "parse raises when a clause is not a hash" do
    assert_raises(EligibilityRule::ParseError) { EligibilityRule.parse({ "any_of" => ["open"] }) }
  end

  # ---- compact grammar ----

  test "parses the compact open form" do
    r = EligibilityRule.parse("open", collective: @collective)
    assert_equal({ "any_of" => [{ "type" => "open" }] }, r.to_h)
  end

  test "resolves handles to user ids" do
    alice = make_user("alice")
    bob = make_user("bob")
    r = EligibilityRule.parse("users:#{alice.handle},#{bob.handle}", collective: @collective)
    assert_equal [alice.id, bob.id], r.to_h["any_of"].first["user_ids"]
  end

  test "resolves a list truncated_id to a list id" do
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    r = EligibilityRule.parse("list:#{list.truncated_id}", collective: @collective)
    assert_equal list.id, r.to_h["any_of"].first["list_id"]
  end

  test "parses a multi-clause compact string" do
    alice = make_user("alice")
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    r = EligibilityRule.parse("users:#{alice.handle} role:admin list:#{list.truncated_id}",
                              collective: @collective)

    assert_equal 3, r.to_h["any_of"].size
    assert_equal "users", r.to_h["any_of"][0]["type"]
    assert_equal "role",  r.to_h["any_of"][1]["type"]
    assert_equal "list",  r.to_h["any_of"][2]["type"]
  end

  test "raises on an unresolvable handle" do
    assert_raises(EligibilityRule::ParseError) do
      EligibilityRule.parse("users:nobody-here", collective: @collective)
    end
  end

  test "raises on a malformed compact clause" do
    assert_raises(EligibilityRule::ParseError) do
      EligibilityRule.parse("users", collective: @collective)
    end
  end

  test "round-trips through the compact grammar" do
    alice = make_user("alice")
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    original = EligibilityRule.parse(
      "users:#{alice.handle} role:admin list:#{list.truncated_id}", collective: @collective
    )
    round_tripped = EligibilityRule.parse(original.to_s(collective: @collective), collective: @collective)

    assert_equal original.to_h, round_tripped.to_h
  end

  test "to_s renders the open default" do
    assert_equal "open", EligibilityRule.default.to_s(collective: @collective)
  end

  # ---- describe ----

  test "describe names the clauses in a readable sentence" do
    alice = make_user("alice")
    r = rule({ "any_of" => [
      { "type" => "users", "user_ids" => [alice.id] },
      { "type" => "role", "role" => "admin" },
    ] })
    description = r.describe(collective: @collective)

    assert_includes description, alice.name
    assert_includes description, "admin"
  end

  test "describe of the default says everyone" do
    assert_match(/every/i, EligibilityRule.default.describe(collective: @collective))
  end
end
