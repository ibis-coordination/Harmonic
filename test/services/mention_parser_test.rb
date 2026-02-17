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
