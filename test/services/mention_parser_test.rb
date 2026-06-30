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

  # The main-collective trio claims the literal TenantUser handle "trio" so its
  # /u/trio profile resolves via the normal handle index. Without this guard,
  # mentioning @trio in a non-main collective would resolve to BOTH the
  # non-main collective's trio (via the magic) AND the main collective's trio
  # (via the index) — fanning the mention out to a trio that isn't part of
  # the conversation.
  test "parse with collective context does not also resolve @trio to the index user with handle 'trio'" do
    tenant, main_collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: main_collective.handle)

    main_trio = User.create!(
      email: "main_trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Main Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    tenant.add_user!(main_trio, handle: "trio")  # claims the literal handle
    main_collective.update!(trio_user: main_trio)

    other_collective = create_collective(tenant: tenant, created_by: user, handle: "other-#{SecureRandom.hex(4)}")
    other_trio = User.create!(
      email: "other_trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Other Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    tenant.add_user!(other_trio, handle: "trio-#{SecureRandom.hex(4)}")
    other_collective.update!(trio_user: other_trio)

    result = MentionParser.parse("@trio", tenant_id: tenant.id, collective: other_collective)

    assert_equal [other_trio.id], result.map(&:id),
      "expected only the other collective's trio, got #{result.map { |u| [u.id, u.name] }.inspect}"
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

  # === resolve_paths tests ===

  test "resolve_paths returns empty hash for blank text or tenant" do
    assert_equal({}, MentionParser.resolve_paths(nil, tenant_id: "123"))
    assert_equal({}, MentionParser.resolve_paths("@alice", tenant_id: nil))
  end

  test "resolve_paths maps resolvable handles to their profile paths" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")

    result = MentionParser.resolve_paths("Hello @alice!", tenant_id: tenant.id)

    assert_equal({ "alice" => "/u/alice" }, result)
  end

  test "resolve_paths omits handles that do not resolve to a user" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")

    result = MentionParser.resolve_paths("Hey @alice and @nobody", tenant_id: tenant.id)

    assert_equal({ "alice" => "/u/alice" }, result)
  end

  test "resolve_paths maps @trio to the collective trio profile when collective is provided" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    tenant.add_user!(trio, handle: "trio-#{SecureRandom.hex(4)}")
    collective.update!(trio_user: trio)

    result = MentionParser.resolve_paths("hi @trio", tenant_id: tenant.id, collective: collective)

    assert_equal({ "trio" => "/u/trio" }, result)
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

  # === code-span / code-block exclusion (#299) ===

  test "extract_handles skips a handle inside an inline code span" do
    assert_equal [], MentionParser.extract_handles("Enable it by mentioning `@trio` in a note.")
  end

  test "extract_handles skips handles inside a fenced code block" do
    text = <<~MD
      Here is an example:

      ```
      @alice please review
      ```

      Done.
    MD

    assert_equal [], MentionParser.extract_handles(text)
  end

  test "extract_handles skips handles in a tilde-fenced code block" do
    text = "~~~\n@bob ping\n~~~"

    assert_equal [], MentionParser.extract_handles(text)
  end

  test "extract_handles still returns a real handle alongside a code-span example" do
    result = MentionParser.extract_handles("Hey @alice, mention people like `@bob` to ping them.")

    assert_equal ["alice"], result
  end

  test "extract_handles still matches a normal handle adjacent to a code span" do
    result = MentionParser.extract_handles("`code` then @carol")

    assert_equal ["carol"], result
  end

  test "extract_handles is unaffected by a lone unbalanced backtick" do
    result = MentionParser.extract_handles("a stray ` and then @dave")

    assert_equal ["dave"], result
  end

  test "parse does not notify a handle that only appears inside a code span" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")

    # @alice resolves normally, but here it appears only inside a code span, so
    # it must not generate a mention notification.
    result = MentionParser.parse("Document it as `@alice`.", tenant_id: tenant.id)

    assert_empty result
  end

  # An indented (4-space) code block is just as much "code" as a fenced one and
  # renders as literal text, so handles inside it must not notify. The blank
  # line before the indent is what makes it a code block rather than a
  # paragraph continuation — see the contrast test below.
  test "extract_handles skips handles inside an indented code block" do
    text = <<~MD
      Here is an example:

          @alice please review

      Done.
    MD

    assert_equal [], MentionParser.extract_handles(text)
  end

  test "extract_handles skips handles inside a tab-indented code block" do
    text = "Example:\n\n\t@bob ping\n\nDone."

    assert_equal [], MentionParser.extract_handles(text)
  end

  # The contrast to the indented-code-block case: with no blank line before it,
  # an indented line is a lazy paragraph continuation, NOT a code block, so the
  # handle renders as a live link and must still notify. A regex that blanked
  # any 4-space-indented line would wrongly drop this; deferring to the Markdown
  # tokenizer (as the renderer does) gets the distinction right.
  test "extract_handles still returns a handle on an indented paragraph continuation line" do
    text = "Talking about\n    @carol here."

    assert_equal ["carol"], MentionParser.extract_handles(text)
  end

  # Nested list items are indented but are not code — they render as normal text
  # with live mentions, so they must still notify.
  test "extract_handles still returns a handle inside a nested list item" do
    text = "- outer point\n  - inner mentioning @dave"

    assert_equal ["dave"], MentionParser.extract_handles(text)
  end
end
