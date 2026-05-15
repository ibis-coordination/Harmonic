require "test_helper"

class MentionParserTest < ActiveSupport::TestCase
  test "parse returns empty array for blank text" do
    assert_equal [], MentionParser.parse(nil, tenant_id: "123")
    assert_equal [], MentionParser.parse("", tenant_id: "123")
  end

  test "parse returns empty array for blank tenant_id" do
    assert_equal [], MentionParser.parse("Hello @alice", tenant_id: nil)
    assert_equal [], MentionParser.parse("Hello @alice", tenant_id: "")
  end

  test "parse returns empty array when no mentions" do
    tenant, _collective, _user = create_tenant_collective_user
    assert_equal [], MentionParser.parse("Hello world", tenant_id: tenant.id)
  end

  test "parse returns users for valid mentions" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Set a known handle for the user
    user.tenant_user.update!(handle: "alice")

    result = MentionParser.parse("Hello @alice, how are you?", tenant_id: tenant.id)

    assert_equal 1, result.size
    assert_equal user.id, result.first.id
  end

  test "parse handles multiple mentions" do
    tenant, collective, user1 = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    user1.tenant_user.update!(handle: "alice")

    user2 = create_user(email: "bob@example.com", name: "Bob")
    tenant.add_user!(user2)
    user2.tenant_user.update!(handle: "bob")

    result = MentionParser.parse("Hello @alice and @bob!", tenant_id: tenant.id)

    assert_equal 2, result.size
    assert_includes result.map(&:id), user1.id
    assert_includes result.map(&:id), user2.id
  end

  test "parse ignores duplicate mentions" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    user.tenant_user.update!(handle: "alice")

    result = MentionParser.parse("Hello @alice and @alice again!", tenant_id: tenant.id)

    assert_equal 1, result.size
    assert_equal user.id, result.first.id
  end

  # === @trio special case ===

  test "parse resolves @trio to the collective's trio_user when collective is provided" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio",
      user_type: "ai_agent",
      system_role: "trio",
      parent_id: nil,
    )
    collective.update!(trio_user: trio)

    result = MentionParser.parse("hi @trio please help", tenant_id: tenant.id, collective: collective)

    assert_includes result.map(&:id), trio.id
    assert_not_includes result.map(&:id), user.id  # @trio in text doesn't grab any other user
  end

  test "parse returns nothing for @trio when collective has no trio_user" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    assert_nil collective.trio_user, "precondition"

    result = MentionParser.parse("hi @trio please help", tenant_id: tenant.id, collective: collective)

    assert_equal [], result
  end

  test "parse ignores @trio when no collective is provided" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    collective.update!(trio_user: trio)

    # No collective kwarg → @trio just looks for a user with handle "trio"
    # (and trio's stored handle is random hex, not "trio"), so resolves to nothing.
    result = MentionParser.parse("hi @trio please help", tenant_id: tenant.id)

    assert_equal [], result
  end

  test "parse resolves @trio in one collective to that collective's trio, not another" do
    tenant, collective_a, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective_a.handle)

    collective_b = create_collective(tenant: tenant, created_by: user, handle: "second-collective-#{SecureRandom.hex(4)}")
    trio_a = User.create!(
      email: "trio_a_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio A", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    trio_b = User.create!(
      email: "trio_b_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio B", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    collective_a.update!(trio_user: trio_a)
    collective_b.update!(trio_user: trio_b)

    result_a = MentionParser.parse("@trio", tenant_id: tenant.id, collective: collective_a)
    result_b = MentionParser.parse("@trio", tenant_id: tenant.id, collective: collective_b)

    assert_equal [trio_a.id], result_a.map(&:id)
    assert_equal [trio_b.id], result_b.map(&:id)
  end

  test "parse_for_notification resolves @trio to the collective's trio_user" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    tenant.add_user!(trio, handle: "trio-#{SecureRandom.hex(4)}")
    collective.add_user!(trio)
    collective.update!(trio_user: trio)

    result = MentionParser.parse_for_notification(
      "@trio help us out", tenant_id: tenant.id, collective: collective, exclude_user: user,
    )

    assert_includes result.map(&:id), trio.id
  end

  test "parse ignores mentions that don't match users" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    user.tenant_user.update!(handle: "alice")

    result = MentionParser.parse("Hello @nonexistent and @alice!", tenant_id: tenant.id)

    assert_equal 1, result.size
    assert_equal user.id, result.first.id
  end

  test "extract_handles returns handles from text" do
    result = MentionParser.extract_handles("Hello @alice and @bob!")

    assert_equal 2, result.size
    assert_includes result, "alice"
    assert_includes result, "bob"
  end

  test "extract_handles handles underscores and hyphens" do
    result = MentionParser.extract_handles("Hello @alice_smith and @bob-jones!")

    assert_equal 2, result.size
    assert_includes result, "alice_smith"
    assert_includes result, "bob-jones"
  end

  # === parse_for_notification tests ===

  test "parse_for_notification excludes the specified user" do
    tenant, collective, user = create_tenant_collective_user
    user.tenant_user.update!(handle: "alice")

    result = MentionParser.parse_for_notification(
      "Hello @alice",
      tenant_id: tenant.id,
      collective: collective,
      exclude_user: user,
    )

    assert_empty result
  end

  test "parse_for_notification excludes non-members of the collective" do
    tenant, collective, user = create_tenant_collective_user
    user.tenant_user.update!(handle: "alice")

    non_member = create_user(email: "outsider@example.com", name: "Outsider")
    tenant.add_user!(non_member)
    non_member.tenant_user.update!(handle: "outsider")
    # outsider is NOT added to the collective

    result = MentionParser.parse_for_notification(
      "Hey @outsider check this out",
      tenant_id: tenant.id,
      collective: collective,
      exclude_user: user,
    )

    assert_empty result
  end

  test "parse_for_notification returns valid collective members" do
    tenant, collective, user = create_tenant_collective_user
    user.tenant_user.update!(handle: "alice")

    member = create_user(email: "bob@example.com", name: "Bob")
    tenant.add_user!(member)
    member.tenant_user.update!(handle: "bob")
    collective.add_user!(member)

    result = MentionParser.parse_for_notification(
      "Hey @bob and @alice check this",
      tenant_id: tenant.id,
      collective: collective,
      exclude_user: user,
    )

    assert_equal 1, result.size
    assert_equal member.id, result.first.id
  end

  test "parse_for_notification returns empty for blank text" do
    tenant, collective, user = create_tenant_collective_user

    result = MentionParser.parse_for_notification(
      "",
      tenant_id: tenant.id,
      collective: collective,
      exclude_user: user,
    )

    assert_empty result
  end

  # === extract_handles tests ===

  test "extract_handles returns empty array for blank text" do
    assert_equal [], MentionParser.extract_handles(nil)
    assert_equal [], MentionParser.extract_handles("")
  end

  test "extract_handles ignores duplicate handles" do
    result = MentionParser.extract_handles("Hello @alice and @alice again!")

    assert_equal 1, result.size
    assert_includes result, "alice"
  end
end
