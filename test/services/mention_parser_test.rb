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

  # === persona tags (@cadence) and the ensemble tag (@trio) ===

  # Mirrors PersonaActivator's activation state: tenant handle, membership,
  # and the activation roles — which @cadence / @trio resolution key off.
  def activate_persona!(tenant, collective, agent, role: "cadence", handle: nil)
    handle ||= "#{role}-#{SecureRandom.hex(4)}"
    tenant.add_user!(agent, handle: handle) unless agent.tenant_users.exists?(tenant_id: tenant.id)
    collective.add_user!(agent) unless collective.user_is_member?(agent)
    collective.collective_members.find_by!(user_id: agent.id).add_roles!([role, "trio"])
    collective.clear_persona_user_cache!
  end

  def create_persona_user!(role: "cadence", name: "Cadence")
    User.create!(
      email: "#{role}_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: name, user_type: "ai_agent", system_role: role, parent_id: nil,
    )
  end

  test "parse resolves @cadence to the collective's cadence when collective is provided" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    cadence = create_persona_user!
    activate_persona!(tenant, collective, cadence)

    result = MentionParser.parse("hi @cadence please help", tenant_id: tenant.id, collective: collective)

    assert_includes result.map(&:id), cadence.id
    assert_not_includes result.map(&:id), user.id  # @cadence in text doesn't grab any other user
  end

  test "@cadence resolves through the persona role, not membership alone" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    cadence = create_persona_user!
    tenant.add_user!(cadence, handle: "cadence-#{SecureRandom.hex(4)}")
    collective.add_user!(cadence)
    # Membership WITHOUT the persona role — a deactivated persona's state.
    result = MentionParser.parse("@cadence", tenant_id: tenant.id, collective: collective)
    assert_equal [], result.map(&:id), "membership without the role must not resolve"

    collective.collective_members.find_by!(user_id: cadence.id).add_role!("cadence")
    result = MentionParser.parse("@cadence", tenant_id: tenant.id, collective: collective)
    assert_equal [cadence.id], result.map(&:id), "the persona role alone must resolve"
  end

  test "parse returns nothing for @cadence when collective has no active persona" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    assert_empty collective.users_with_role("cadence"), "precondition"

    result = MentionParser.parse("hi @cadence please help", tenant_id: tenant.id, collective: collective)

    assert_equal [], result
  end

  test "parse ignores @cadence when no collective is provided" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    cadence = create_persona_user!
    activate_persona!(tenant, collective, cadence)

    # No collective kwarg → @cadence just looks for a user with handle
    # "cadence" (and the persona's stored handle is prefixed), so resolves
    # to nothing.
    result = MentionParser.parse("hi @cadence please help", tenant_id: tenant.id)

    assert_equal [], result
  end

  # A legacy squatter holding the literal tag handle must not receive the
  # mention: within a collective, persona tags resolve locally, never through
  # the tenant-wide handle index.
  test "parse with collective context does not also resolve @cadence to an index user with handle 'cadence'" do
    tenant, main_collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: main_collective.handle)

    squatter = create_user(email: "sq_#{SecureRandom.hex(4)}@example.com")
    squatter_tu = tenant.add_user!(squatter)
    # Bypass validation the way a pre-reservation row would exist.
    squatter_tu.update_column(:handle, "cadence")

    other_collective = create_collective(tenant: tenant, created_by: user, handle: "other-#{SecureRandom.hex(4)}")
    other_cadence = create_persona_user!
    activate_persona!(tenant, other_collective, other_cadence)

    result = MentionParser.parse("@cadence", tenant_id: tenant.id, collective: other_collective)

    assert_equal [other_cadence.id], result.map(&:id),
      "expected only the collective's own persona, got #{result.map { |u| [u.id, u.name] }.inspect}"
  end

  test "parse resolves @cadence in one collective to that collective's persona, not another" do
    tenant, collective_a, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective_a.handle)

    collective_b = create_collective(tenant: tenant, created_by: user, handle: "second-collective-#{SecureRandom.hex(4)}")
    cadence_a = create_persona_user!(name: "Cadence A")
    cadence_b = create_persona_user!(name: "Cadence B")
    activate_persona!(tenant, collective_a, cadence_a)
    activate_persona!(tenant, collective_b, cadence_b)

    result_a = MentionParser.parse("@cadence", tenant_id: tenant.id, collective: collective_a)
    result_b = MentionParser.parse("@cadence", tenant_id: tenant.id, collective: collective_b)

    assert_equal [cadence_a.id], result_a.map(&:id)
    assert_equal [cadence_b.id], result_b.map(&:id)
  end

  test "parse_for_notification resolves @cadence to the collective's persona" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    cadence = create_persona_user!
    activate_persona!(tenant, collective, cadence)

    result = MentionParser.parse_for_notification(
      "@cadence help us out", tenant_id: tenant.id, collective: collective, exclude_user: user,
    )

    assert_includes result.map(&:id), cadence.id
  end

  test "@trio fans out to every active persona via the ensemble role" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    cadence = create_persona_user!
    melody = create_persona_user!(role: "melody", name: "Melody")
    activate_persona!(tenant, collective, cadence)
    activate_persona!(tenant, collective, melody, role: "melody")

    result = MentionParser.parse("@trio status check", tenant_id: tenant.id, collective: collective)

    assert_equal [cadence.id, melody.id].sort, result.map(&:id).sort
    assert_not_includes result.map(&:id), user.id
  end

  test "@trio resolves to nothing when no persona is active" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    result = MentionParser.parse("@trio anyone?", tenant_id: tenant.id, collective: collective)

    assert_equal [], result
  end

  test "@trio is collective-local — one collective's mention never reaches another's personas" do
    tenant, collective_a, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective_a.handle)

    collective_b = create_collective(tenant: tenant, created_by: user, handle: "ens-b-#{SecureRandom.hex(4)}")
    cadence_b = create_persona_user!
    activate_persona!(tenant, collective_b, cadence_b)

    result = MentionParser.parse("@trio", tenant_id: tenant.id, collective: collective_a)

    assert_equal [], result, "collective A has no personas; B's must not leak in"
  end

  # === group tags: @everyone / @admins ===

  test "parse resolves @admins to the collective's admins for any author" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])

    member = create_user(email: "m@example.com", name: "Member")
    tenant.add_user!(member)
    collective.add_user!(member)

    # A non-admin author still expands @admins.
    result = MentionParser.parse("heads up @admins", tenant_id: tenant.id, collective: collective, author: member)

    assert_includes result.map(&:id), admin.id
    assert_not_includes result.map(&:id), member.id
  end

  test "parse resolves every role tag to its role holders for any author" do
    # The role tags are derived from CollectiveMember.valid_roles, so this
    # covers @representatives / @summarizers as well as @admins, and any role
    # added later. Each expands to the members holding that role.
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])

    rep = create_user(email: "rep@example.com", name: "Rep")
    tenant.add_user!(rep)
    collective.add_user!(rep, roles: ["representative"])

    summarizer = create_user(email: "sum@example.com", name: "Summarizer")
    tenant.add_user!(summarizer)
    collective.add_user!(summarizer, roles: ["summarizer"])

    # A plain member (author) with no role can still use the role tags.
    reps = MentionParser.parse("ping @representatives", tenant_id: tenant.id, collective: collective, author: rep)
    assert_equal [rep.id], reps.map(&:id)

    sums = MentionParser.parse("ping @summarizers", tenant_id: tenant.id, collective: collective, author: rep)
    assert_equal [summarizer.id], sums.map(&:id)
  end

  test "parse resolves @automators and @moderators to their role holders" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])

    automator = create_user(email: "auto@example.com", name: "Automator")
    tenant.add_user!(automator)
    collective.add_user!(automator, roles: ["automator"])

    moderator = create_user(email: "mod@example.com", name: "Moderator")
    tenant.add_user!(moderator)
    collective.add_user!(moderator, roles: ["moderator"])

    autos = MentionParser.parse("ping @automators", tenant_id: tenant.id, collective: collective, author: admin)
    assert_equal [automator.id], autos.map(&:id)

    mods = MentionParser.parse("ping @moderators", tenant_id: tenant.id, collective: collective, author: admin)
    assert_equal [moderator.id], mods.map(&:id)
  end

  test "parse resolves @everyone to all members when the author is an admin" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])

    member = create_user(email: "m@example.com", name: "Member")
    tenant.add_user!(member)
    collective.add_user!(member)

    result = MentionParser.parse("@everyone please read", tenant_id: tenant.id, collective: collective, author: admin)

    assert_includes result.map(&:id), admin.id
    assert_includes result.map(&:id), member.id
  end

  test "parse does not expand @everyone when the author is not an admin" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])

    member = create_user(email: "m@example.com", name: "Member")
    tenant.add_user!(member)
    collective.add_user!(member)

    result = MentionParser.parse("@everyone please read", tenant_id: tenant.id, collective: collective, author: member)

    assert_equal [], result
  end

  test "parse does not expand @everyone without a known author" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])

    # No author kwarg → the admin-only gate can't be satisfied, so no fan-out.
    result = MentionParser.parse("@everyone please read", tenant_id: tenant.id, collective: collective)

    assert_equal [], result
  end

  test "parse ignores group tags when no collective is provided" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])

    result = MentionParser.parse("@everyone @admins", tenant_id: tenant.id, author: admin)

    assert_equal [], result
  end

  test "parse dedupes a user named both directly and via a group tag" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    collective.add_user!(admin, roles: ["admin"])
    admin.tenant_user.update!(handle: "alice")

    result = MentionParser.parse("@everyone and especially @alice", tenant_id: tenant.id, collective: collective, author: admin)

    assert_equal 1, result.count { |u| u.id == admin.id }
  end

  test "resolve_paths links group tags to the collective for any reader" do
    tenant, collective, _admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    result = MentionParser.resolve_paths("@everyone and @admins", tenant_id: tenant.id, collective: collective)

    assert_equal collective.path, result["everyone"]
    assert_equal collective.path, result["admins"]
  end

  test "resolve_paths leaves group tags unresolved without a collective" do
    tenant, collective, _admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    result = MentionParser.resolve_paths("@everyone", tenant_id: tenant.id)

    assert_equal({}, result)
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

  test "resolve_paths maps @cadence to the persona's own profile when collective is provided" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    cadence = create_persona_user!
    activate_persona!(tenant, collective, cadence)

    result = MentionParser.resolve_paths("hi @cadence", tenant_id: tenant.id, collective: collective)

    # The @cadence tag links to the local persona's own profile (its real
    # handle), not to a shared /u/cadence.
    assert_equal({ "cadence" => cadence.reload.path }, result)
    assert_match(%r{\A/u/cadence-}, result["cadence"])
  end

  test "resolve_paths maps @trio to the collective — the ensemble names a set, not a profile" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    cadence = create_persona_user!
    activate_persona!(tenant, collective, cadence)

    result = MentionParser.resolve_paths("hi @trio", tenant_id: tenant.id, collective: collective)

    assert_equal({ "trio" => collective.path }, result)
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
