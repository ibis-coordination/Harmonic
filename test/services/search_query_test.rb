# typed: false

require "test_helper"

class SearchQueryTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    # For Notes, searchable_text uses body (text) only since title is derived from text
    @note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "Budget proposal details")
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user, question: "Approve budget?")
    @commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user, title: "Review budget")

    # Ensure search index is populated (callbacks should do this, but let's be explicit)
    SearchIndexer.reindex(@note)
    SearchIndexer.reindex(@decision)
    SearchIndexer.reindex(@commitment)
  end

  # Full-text search tests

  test "full-text search finds matching content" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "budget cycle:all"
    )

    results = search.results
    assert_equal 3, results.count
    assert results.all? { |r| r.title.downcase.include?("budget") || r.searchable_text.downcase.include?("budget") }
  end

  test "full-text search returns empty for non-matching query" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "nonexistent cycle:all"
    )

    assert_empty search.results
  end

  test "search without query returns no results" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      params: { cycle: "all" }
    )

    assert_equal 0, search.results.count
  end

  test "search with cycle:all returns all results" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "cycle:all"
    )

    assert_equal 3, search.results.count
  end

  # Type filter tests

  test "type filter restricts to specified types" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "type:note cycle:all"
    )

    results = search.results
    assert results.all? { |r| r.item_type == "Note" }
    assert_equal 1, results.count
  end

  test "type filter accepts comma-separated types" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "type:note,decision cycle:all"
    )

    results = search.results
    assert results.all? { |r| %w[Note Decision].include?(r.item_type) }
    assert_equal 2, results.count
  end

  test "type=all returns all types" do
    # When no type filter is specified, all types are returned
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "cycle:all"
    )

    types = search.results.map(&:item_type).uniq
    assert_includes types, "Note"
    assert_includes types, "Decision"
    assert_includes types, "Commitment"
    assert_equal 3, search.results.count
  end

  test "exclude_types excludes specified types" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "-type:note cycle:all"
    )

    results = search.results
    assert results.none? { |r| r.item_type == "Note" }
    assert_equal 2, results.count
  end

  test "exclude_types works with DSL via raw_query" do
    # This is the bug fix: -type:note should exclude notes
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "-type:note cycle:all"
    )

    results = search.results
    assert results.none? { |r| r.item_type == "Note" }
    assert_equal 2, results.count
  end

  test "exclude_types works with collective scope via raw_query" do
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "collective:#{@collective.handle} -type:note cycle:all"
    )

    results = search.results
    assert results.none? { |r| r.item_type == "Note" }
    assert_equal 2, results.count
  end

  # Subtype filter tests

  test "subtype:comment returns only comments" do
    comment = @note.add_comment(text: "This is a comment", created_by: @user)
    SearchIndexer.reindex(comment)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "subtype:comment cycle:all"
    )

    results = search.results
    assert results.all? { |r| r.subtype == "comment" }
    assert_includes results.pluck(:item_id), comment.id
  end

  test "-subtype:comment excludes comments and includes regular notes" do
    # Reindex the note with new indexer (stores "post" subtype)
    SearchIndexer.reindex(@note)
    comment = @note.add_comment(text: "This is a comment", created_by: @user)
    SearchIndexer.reindex(comment)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "type:note -subtype:comment cycle:all"
    )

    results = search.results
    # Should include regular notes (subtype is "post")
    assert_includes results.pluck(:item_id), @note.id
    # Should exclude comments
    assert_not_includes results.pluck(:item_id), comment.id
    # All results should have non-comment subtype
    assert results.none? { |r| r.subtype == "comment" }
  end

  test "subtype:summary returns only summary notes" do
    summary = Note.create!(
      subtype: "summary", text: "Summary text",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    SearchIndexer.reindex(summary)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "subtype:summary cycle:all"
    )

    results = search.results
    assert results.all? { |r| r.subtype == "summary" }
    assert_includes results.pluck(:item_id), summary.id
  end

  test "subtype:statement returns only statement notes" do
    statement = Note.create!(
      subtype: "statement", text: "Final statement",
      statementable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    SearchIndexer.reindex(statement)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "subtype:statement cycle:all"
    )

    results = search.results
    assert results.all? { |r| r.subtype == "statement" }
    assert_includes results.pluck(:item_id), statement.id
  end

  test "-subtype:summary excludes summaries" do
    SearchIndexer.reindex(@note)
    summary = Note.create!(
      subtype: "summary", text: "Summary text",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    SearchIndexer.reindex(summary)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "type:note -subtype:summary cycle:all"
    )

    results = search.results
    assert_includes results.pluck(:item_id), @note.id
    assert_not_includes results.pluck(:item_id), summary.id
    assert results.none? { |r| r.subtype == "summary" }
  end

  # Time window tests

  test "cycle filter restricts to time window" do
    old_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Old note")
    old_note.update_columns(created_at: 1.month.ago, deadline: 1.month.ago + 1.day)
    SearchIndexer.reindex(old_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      params: { cycle: "today" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, old_note.id
  end

  test "cycle=all returns all items" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "cycle:all"
    )

    assert_equal 3, search.results.count
  end

  # Ownership filters

  test "mine filter returns items created by current user" do
    other_user = create_user(email: "other_mine@example.com", name: "Other Mine User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    other_note = create_note(tenant: @tenant, collective: @collective, created_by: other_user, title: "Other's note")
    SearchIndexer.reindex(other_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "creator:@#{@user.handle} cycle:all"
    )

    assert search.results.all? { |r| r.created_by_id == @user.id }
    assert_not_includes search.results.pluck(:item_id), other_note.id
  end

  test "creator: handle lookup is case-insensitive" do
    # Agents may construct a search from a @Mention they saw rendered in
    # mixed case. The end-to-end contract is: parser downcases operator
    # values + TenantUser model normalizes handle on query. Pin both layers
    # via this regression test.
    my_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "My note")
    SearchIndexer.reindex(my_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "creator:@#{@user.handle.upcase} cycle:all"
    )
    assert_includes search.results.pluck(:item_id), my_note.id,
                    "creator:@HANDLE (uppercase) should match the same user as the stored lowercase handle"
  end

  test "collective: handle lookup is case-insensitive when collective context is unset" do
    # `collective:HANDLE` only runs the find_by path when the search has no
    # collective context (the early-return guard otherwise). Collective has
    # no `normalizes :handle`, so this works only because the parser
    # downcases operator values. Pin by putting notes in TWO collectives and
    # confirming the upcased operator narrows to the named one only.
    other_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      handle: "case-insens-other-#{SecureRandom.hex(2)}"
    )
    other_collective.add_user!(@user)
    in_target = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "in target")
    in_other = create_note(tenant: @tenant, collective: other_collective, created_by: @user, title: "in other")
    SearchIndexer.reindex(in_target)
    SearchIndexer.reindex(in_other)

    search = SearchQuery.new(
      tenant: @tenant, collective: nil, current_user: @user,
      raw_query: "collective:#{@collective.handle.upcase} cycle:all"
    )
    ids = search.results.pluck(:item_id)
    assert_includes ids, in_target.id,
                    "collective:HANDLE (uppercase) should resolve to the target collective"
    refute_includes ids, in_other.id,
                    "collective:HANDLE must narrow — note in other collective should not leak in"
  end

  test "not_mine filter excludes items created by current user" do
    other_user = create_user(email: "other_not_mine@example.com", name: "Other Not Mine User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    other_note = create_note(tenant: @tenant, collective: @collective, created_by: other_user, title: "Other's note")
    SearchIndexer.reindex(other_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "-creator:@#{@user.handle} cycle:all"
    )

    assert search.results.none? { |r| r.created_by_id == @user.id }
    assert_includes search.results.pluck(:item_id), other_note.id
  end

  # Status filters

  test "open filter returns items with future deadlines" do
    closed_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Closed note")
    closed_note.update_columns(deadline: 1.day.ago)
    SearchIndexer.reindex(closed_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "status:open cycle:all"
    )

    assert search.results.all? { |r| r.deadline > Time.current }
    assert_not_includes search.results.pluck(:item_id), closed_note.id
  end

  test "closed filter returns items with past deadlines" do
    closed_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Closed note")
    closed_note.update_columns(deadline: 1.day.ago)
    SearchIndexer.reindex(closed_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "status:closed cycle:all"
    )

    assert search.results.all? { |r| r.deadline <= Time.current }
    assert_includes search.results.pluck(:item_id), closed_note.id
  end

  # Presence filters

  test "has_backlinks filter returns items with backlinks" do
    note2 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Linking note")
    Link.create!(from_linkable: note2, to_linkable: @note, tenant_id: @tenant.id, collective_id: @collective.id)
    SearchIndexer.reindex(@note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "min-backlinks:1 cycle:all"
    )

    assert search.results.all? { |r| r.backlink_count > 0 }
    assert_includes search.results.pluck(:item_id), @note.id
  end

  # Sorting tests

  test "sort_by=created_at-desc returns newest first" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "sort:newest cycle:all"
    )

    results = search.results.to_a
    created_ats = results.map(&:created_at)
    assert_equal created_ats, created_ats.sort.reverse
  end

  test "sort_by=created_at-asc returns oldest first" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "sort:oldest cycle:all"
    )

    results = search.results.to_a
    created_ats = results.map(&:created_at)
    assert_equal created_ats, created_ats.sort
  end

  test "sort_by=relevance-desc works with text search" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "budget sort:relevance cycle:all"
    )

    results = search.results
    # Should not raise and should return results
    assert results.respond_to?(:to_a)
  end

  # Pagination tests

  test "cursor pagination returns next page without overlap" do
    10.times do |i|
      note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note #{i}")
      SearchIndexer.reindex(note)
    end

    search1 = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "limit:5 cycle:all"
    )

    page1_ids = search1.paginated_results.pluck(:item_id)
    cursor = search1.next_cursor

    search2 = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "limit:5 cycle:all",
      params: { cursor: cursor }
    )

    page2_ids = search2.paginated_results.pluck(:item_id)

    # No overlap between pages
    assert_empty(page1_ids & page2_ids)
  end

  test "per_page is clamped to valid range" do
    search_low = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "limit:-5 cycle:all"
    )
    assert_equal 25, search_low.per_page

    search_high = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "limit:500 cycle:all"
    )
    assert_equal 100, search_high.per_page
  end

  # Grouping tests

  test "grouped_results groups by item_type" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "group:type cycle:all"
    )

    grouped = search.grouped_results
    group_keys = grouped.map(&:first)

    assert_includes group_keys, "Note"
    assert_includes group_keys, "Decision"
    assert_includes group_keys, "Commitment"
  end

  test "group_by=none returns flat results" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "group:none cycle:all"
    )

    grouped = search.grouped_results
    assert_equal 1, grouped.length
    assert_nil grouped.first.first
  end

  test "grouped_results groups by status" do
    closed_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Closed note")
    closed_note.update_columns(deadline: 1.day.ago)
    SearchIndexer.reindex(closed_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "group:status cycle:all"
    )

    grouped = search.grouped_results
    group_keys = grouped.map(&:first)

    assert_includes group_keys, "open"
    assert_includes group_keys, "closed"
  end

  # Multi-tenancy tests

  test "results are scoped to tenant and collective" do
    other_tenant = create_tenant(subdomain: "other")
    other_user = create_user(email: "other_tenant@example.com")
    other_tenant.add_user!(other_user)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, handle: "other-collective")
    other_note = create_note(tenant: other_tenant, collective: other_collective, created_by: other_user, title: "Other tenant note")
    SearchIndexer.reindex(other_note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, other_note.id
  end

  # to_params tests

  test "to_params returns query parameters" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      params: { q: "test", type: "note", cycle: "today", filters: "mine", sort_by: "created_at-desc" }
    )

    params = search.to_params
    assert_equal "test", params[:q]
    assert_equal "note", params[:type]
    assert_equal "today", params[:cycle]
    assert_equal "mine", params[:filters]
    assert_equal "created_at-desc", params[:sort_by]
  end

  # Options methods tests

  test "cycle_options returns valid options" do
    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      params: {}
    )

    options = search.cycle_options
    assert options.is_a?(Array)
    assert options.all? { |opt| opt.is_a?(Array) && opt.length == 2 }
    assert options.any? { |opt| opt[1] == "today" }
    assert options.any? { |opt| opt[1] == "all" }
  end

  test "sort_by_options includes relevance when query is present" do
    search_with_query = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      params: { q: "test" }
    )
    assert search_with_query.sort_by_options.any? { |opt| opt[1] == "relevance-desc" }

    search_without_query = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      params: {}
    )
    assert search_without_query.sort_by_options.none? { |opt| opt[1] == "relevance-desc" }
  end

  # Exact phrase matching tests

  test "exact phrase matches consecutive substring" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "Budget proposal review")
    SearchIndexer.reindex(note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: '"Budget proposal"',
      params: { cycle: "all" }
    )

    assert_includes search.results.pluck(:item_id), note.id
  end

  test "exact phrase does NOT match different word order" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "proposal Budget")
    SearchIndexer.reindex(note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: '"Budget proposal"',
      params: { cycle: "all" }
    )

    # Should NOT include the note because word order is different
    assert_not_includes search.results.pluck(:item_id), note.id
  end

  test "exact phrase does NOT match words in different positions" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "more search testing")
    SearchIndexer.reindex(note)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: '"testing more"',
      params: { cycle: "all" }
    )

    # Should NOT include the note because "testing more" is not a consecutive substring
    assert_not_includes search.results.pluck(:item_id), note.id
  end

  # Excluded terms tests

  test "excluded term filters out matching results" do
    note_with_term = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "apple banana")
    note_without_term = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "apple cherry")
    SearchIndexer.reindex(note_with_term)
    SearchIndexer.reindex(note_without_term)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "apple -banana",
      params: { cycle: "all" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, note_with_term.id
    assert_includes result_ids, note_without_term.id
  end

  test "multiple excluded terms filter correctly" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "apple banana")
    note2 = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "apple cherry")
    note3 = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "apple date")
    SearchIndexer.reindex(note1)
    SearchIndexer.reindex(note2)
    SearchIndexer.reindex(note3)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "apple -banana -cherry",
      params: { cycle: "all" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, note1.id
    assert_not_includes result_ids, note2.id
    assert_includes result_ids, note3.id
  end

  # Tenant-wide search tests

  test "tenant-wide search includes items from collectives user is member of" do
    # Create a collective and add user as member
    member_collective = Collective.create!(
      tenant: @tenant, created_by: @user,
      name: "Member Collective", handle: "member-collective"
    )
    member_collective.add_user!(@user)
    member_note = create_note(tenant: @tenant, collective: member_collective, created_by: @user, text: "member collective content")
    SearchIndexer.reindex(member_note)

    # Tenant-wide search
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "cycle:all"
    )

    assert_includes search.results.pluck(:item_id), member_note.id
  end

  test "tenant-wide search excludes items from collectives user is NOT member of" do
    # Create another user who owns a collective
    other_user = User.create!(name: "Other User", email: "other-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)

    # Create a private collective that @user is NOT a member of
    private_collective = Collective.create!(
      tenant: @tenant, created_by: other_user,
      name: "Private Collective", handle: "private-collective"
    )
    private_collective.add_user!(other_user)
    private_note = create_note(tenant: @tenant, collective: private_collective, created_by: other_user, text: "private collective content")
    SearchIndexer.reindex(private_note)

    # Tenant-wide search as @user (who is NOT a member of private_collective)
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "cycle:all"
    )

    assert_not_includes search.results.pluck(:item_id), private_note.id
  end

  test "tenant-wide search combines member collectives and excludes non-member" do
    # Create a collective user is member of
    member_collective = Collective.create!(
      tenant: @tenant, created_by: @user,
      name: "Member Collective", handle: "member-collective-combo"
    )
    member_collective.add_user!(@user)
    member_note = create_note(tenant: @tenant, collective: member_collective, created_by: @user, text: "member combo")
    SearchIndexer.reindex(member_note)

    # Create another user's private collective
    other_user = User.create!(name: "Other", email: "other-combo-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    private_collective = Collective.create!(
      tenant: @tenant, created_by: other_user,
      name: "Private", handle: "private-combo"
    )
    private_collective.add_user!(other_user)
    private_note = create_note(tenant: @tenant, collective: private_collective, created_by: other_user, text: "private combo")
    SearchIndexer.reindex(private_note)

    # Tenant-wide search
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "combo",
      params: { cycle: "all" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_includes result_ids, member_note.id, "Should include member collective items"
    assert_not_includes result_ids, private_note.id, "Should exclude non-member collective items"
  end

  # Security: explicit collective access control

  test "search with explicit collective the user has NO access to returns no results" do
    # Create another user who owns a private collective
    other_user = User.create!(name: "Collective Owner", email: "owner-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)

    private_collective = Collective.create!(
      tenant: @tenant, created_by: other_user,
      name: "Private Collective", handle: "private-explicit"
    )
    private_collective.add_user!(other_user)
    private_note = create_note(tenant: @tenant, collective: private_collective, created_by: other_user, text: "secret content")
    SearchIndexer.reindex(private_note)

    # Attempt to search with explicit collective the user does NOT have access to
    # This simulates a malicious or buggy caller passing a collective without checking access
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      collective: private_collective,
      raw_query: "cycle:all"
    )

    # Should return NO results because user doesn't have access to this collective
    assert_empty search.results.pluck(:item_id), "Should not expose items from collectives user has no access to"
  end

  test "search with explicit collective the user HAS access to returns results" do
    # Create a collective and add user as member
    member_collective = Collective.create!(
      tenant: @tenant, created_by: @user,
      name: "Member Collective", handle: "member-explicit"
    )
    member_collective.add_user!(@user)
    collective_note = create_note(tenant: @tenant, collective: member_collective, created_by: @user, text: "accessible content")
    SearchIndexer.reindex(collective_note)

    # Search with explicit collective the user has access to
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      collective: member_collective,
      raw_query: "cycle:all"
    )

    assert_includes search.results.pluck(:item_id), collective_note.id
  end

  # collective: operator - collective handle resolution

  test "collective: operator resolves collective by handle" do
    # Create a collective
    target_collective = Collective.create!(
      tenant: @tenant, created_by: @user,
      name: "Target Collective", handle: "target-collective"
    )
    target_collective.add_user!(@user)
    collective_note = create_note(tenant: @tenant, collective: target_collective, created_by: @user, text: "target content")
    SearchIndexer.reindex(collective_note)

    # Search using collective: operator
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "content collective:target-collective cycle:all"
    )

    assert_equal target_collective, search.collective
    assert_includes search.results.pluck(:item_id), collective_note.id
    # Should NOT include items from other collectives
    assert_not_includes search.results.pluck(:item_id), @note.id
  end

  test "collective: operator with invalid handle returns empty results" do
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "content collective:nonexistent-collective cycle:all"
    )

    # Invalid handle means no collective resolved, falls back to tenant-wide
    # Since the handle doesn't exist, @collective is nil
    assert_nil search.collective
  end

  test "collective:main resolves to tenant main collective" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "main collective content")
    SearchIndexer.reindex(main_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "collective:main cycle:all"
    )

    assert_equal main_collective, search.collective
    assert_includes search.results.pluck(:item_id), main_note.id
    # Should NOT include items from other collectives
    assert_not_includes search.results.pluck(:item_id), @note.id
  end

  # visibility: operator tests

  test "visibility:public restricts search to main collective only" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user)
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public main content")
    SearchIndexer.reindex(main_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "visibility:public cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    assert_includes result_ids, main_note.id
    # Should NOT include items from non-main collectives
    assert_not_includes result_ids, @note.id
  end

  test "visibility:private returns only workspace content" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user)
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public main content")
    SearchIndexer.reindex(main_note)

    workspace = @user.private_workspace
    Collective.set_thread_context(workspace)
    workspace_note = create_note(tenant: @tenant, collective: workspace, created_by: @user, text: "private workspace memory")
    SearchIndexer.reindex(workspace_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "visibility:private cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    assert_includes result_ids, workspace_note.id
    assert_not_includes result_ids, main_note.id
    assert_not_includes result_ids, @note.id
  end

  test "visibility:shared returns non-public non-workspace content" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user)
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public main content")
    SearchIndexer.reindex(main_note)

    workspace = @user.private_workspace
    Collective.set_thread_context(workspace)
    workspace_note = create_note(tenant: @tenant, collective: workspace, created_by: @user, text: "private workspace memory")
    SearchIndexer.reindex(workspace_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "visibility:shared cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    # Should include shared collective content
    assert_includes result_ids, @note.id
    # Should NOT include public or workspace content
    assert_not_includes result_ids, main_note.id
    assert_not_includes result_ids, workspace_note.id
  end

  test "-visibility:private excludes workspace content" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user)
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public main content")
    SearchIndexer.reindex(main_note)

    workspace = @user.private_workspace
    Collective.set_thread_context(workspace)
    workspace_note = create_note(tenant: @tenant, collective: workspace, created_by: @user, text: "private workspace memory")
    SearchIndexer.reindex(workspace_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "-visibility:private cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    # Should include public and shared content
    assert_includes result_ids, main_note.id
    assert_includes result_ids, @note.id
    # Should NOT include workspace content
    assert_not_includes result_ids, workspace_note.id
  end

  test "-visibility:public excludes main collective content" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user)
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public main content")
    SearchIndexer.reindex(main_note)

    workspace = @user.private_workspace
    Collective.set_thread_context(workspace)
    workspace_note = create_note(tenant: @tenant, collective: workspace, created_by: @user, text: "private workspace memory")
    SearchIndexer.reindex(workspace_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "-visibility:public cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    # Should include shared and workspace content
    assert_includes result_ids, @note.id
    assert_includes result_ids, workspace_note.id
    # Should NOT include public content
    assert_not_includes result_ids, main_note.id
  end

  test "visibility:public for unauthenticated user returns main collective results" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public unauthenticated content")
    SearchIndexer.reindex(main_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: nil,
      raw_query: "visibility:public cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    assert_includes result_ids, main_note.id
  end

  test "authenticated user always has access to main collective in search" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    # Don't explicitly add user as member — test that main collective is always accessible
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "always accessible content")
    SearchIndexer.reindex(main_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "cycle:all"
    )

    assert_includes search.results.pluck(:item_id), main_note.id
  end

  test "collective: operator respects access control" do
    # Create another user's private collective
    other_user = User.create!(name: "Other", email: "other-in-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    private_collective = Collective.create!(
      tenant: @tenant, created_by: other_user,
      name: "Private", handle: "private-in-test"
    )
    private_collective.add_user!(other_user)
    private_note = create_note(tenant: @tenant, collective: private_collective, created_by: other_user, text: "private in test")
    SearchIndexer.reindex(private_note)

    # Try to search in the private collective as @user (not a member)
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "private collective:private-in-test cycle:all"
    )

    # Collective is resolved (exists) but user doesn't have access
    assert_equal private_collective, search.collective
    # No results because access control prevents it
    assert_empty search.results.pluck(:item_id)
  end

  # list:tuned_in — the home-feed alias

  test "list:tuned_in includes the viewer's own content" do
    # Your own writing stays on your home view: you cannot tune in to
    # yourself, so the alias adds the viewer to the primary-list members.
    @tenant.update!(main_collective: @collective)
    @user.primary_user_list_in!(@tenant)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "list:tuned_in cycle:all"
    )
    assert_includes search.results.pluck(:item_id), @note.id
  end

  test "list:tuned_in includes tuned-in members and excludes strangers" do
    @tenant.update!(main_collective: @collective)
    member = create_user(email: "tuned_member@example.com", name: "Tuned Member")
    stranger = create_user(email: "stranger@example.com", name: "Stranger")
    [member, stranger].each do |u|
      @tenant.add_user!(u)
      @collective.add_user!(u)
    end
    list = @user.primary_user_list_in!(@tenant)
    UserListMember.create!(
      tenant: @tenant, collective: @collective,
      user_list: list, user: member, added_by: @user
    )
    member_note = create_note(tenant: @tenant, collective: @collective, created_by: member, title: "Member note")
    stranger_note = create_note(tenant: @tenant, collective: @collective, created_by: stranger, title: "Stranger note")
    [member_note, stranger_note].each { |n| SearchIndexer.reindex(n) }

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "list:tuned_in cycle:all"
    )
    ids = search.results.pluck(:item_id)
    assert_includes ids, member_note.id
    assert_not_includes ids, stranger_note.id
  end

  test "list filters exclude blocked authors even with stale list membership" do
    # The UserBlock callback removes primary-list memberships at block time,
    # but memberships that predate the callback could linger. The list
    # filter itself must drop block-related authors (same defense the home
    # feed applied before it moved to search).
    @tenant.update!(main_collective: @collective)
    member = create_user(email: "blocked_member@example.com", name: "Blocked Member")
    @tenant.add_user!(member)
    @collective.add_user!(member)
    list = @user.primary_user_list_in!(@tenant)
    UserBlock.create!(tenant: @tenant, blocker: @user, blocked: member)
    # Simulate a stale membership that predates the block validation and
    # callback (both would prevent this today) by skipping validations.
    stale = UserListMember.new(
      tenant: @tenant, collective: @collective,
      user_list: list, user: member, added_by: @user
    )
    stale.save!(validate: false)
    blocked_note = create_note(tenant: @tenant, collective: @collective, created_by: member, title: "Blocked author note")
    SearchIndexer.reindex(blocked_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "list:tuned_in cycle:all"
    )
    assert_not_includes search.results.pluck(:item_id), blocked_note.id
  end

  # Fixed params — structural page scope enforcement

  test "fixed params override conflicting query terms and warn" do
    @tenant.update!(main_collective: @collective)
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "budget visibility:private cycle:all",
      fixed_params: { visibility: "public" }
    )

    warning = search.warnings.find { |w| w.include?("visibility:private") }
    assert warning, "expected a conflict warning, got: #{search.warnings.inspect}"
    assert_includes warning, "visibility:public"
    # Enforced structurally: results are main-collective (public) content.
    assert_not_empty search.results
    assert search.results.all? { |r| r.collective_id == @collective.id }
  end

  test "a blank query with a fixed scope browses everything in scope" do
    @tenant.update!(main_collective: @collective)
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "",
      fixed_params: { visibility: "public" }
    )
    assert_includes search.results.pluck(:item_id), @note.id
  end

  test "a blank query with no fixed scope returns nothing" do
    search = SearchQuery.new(tenant: @tenant, current_user: @user, raw_query: "")
    assert_empty search.results
  end

  test "negating the fixed scope is ignored with a warning" do
    @tenant.update!(main_collective: @collective)
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "budget -visibility:public cycle:all",
      fixed_params: { visibility: "public" }
    )

    warning = search.warnings.find { |w| w.include?("-visibility:public") }
    assert warning, "expected a conflict warning, got: #{search.warnings.inspect}"
    # The negation is dropped; the fixed scope still returns results.
    assert_not_empty search.results
  end

  test "fixed params do not warn when the query does not conflict" do
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "budget cycle:all",
      fixed_params: { visibility: "public" }
    )
    assert_empty search.warnings
  end

  # my: — viewer-state filters

  def add_member(name)
    member = create_user(name: name)
    @tenant.add_user!(member)
    @collective.add_user!(member)
    member
  end

  def notify(user, subject:, dismissed: false, read: false, scheduled_for: nil)
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.notified", actor: @user, subject: subject)
    notification = Notification.create!(tenant: @tenant, event: event, notification_type: "mention", title: "About #{subject.class}")
    NotificationRecipient.create!(
      notification: notification, user: user, channel: "in_app", tenant: @tenant,
      status: dismissed ? "dismissed" : "delivered",
      dismissed_at: dismissed ? Time.current : nil,
      read_at: read || dismissed ? Time.current : nil,
      scheduled_for: scheduled_for,
    )
  end

  def my_search(user, query)
    SearchQuery.new(tenant: @tenant, collective: @collective, current_user: user, raw_query: "#{query} cycle:all")
  end

  test "my:unread returns notes the viewer has not confirmed read; my:read the inverse" do
    viewer = add_member("Reader")

    unread = my_search(viewer, "my:unread").results
    assert_equal [["Note", @note.id]], unread.map { |r| [r.item_type, r.item_id] }

    assert_empty my_search(viewer, "my:read").results

    @note.confirm_read!(viewer)

    assert_empty my_search(viewer, "my:unread").results
    assert_equal [["Note", @note.id]], my_search(viewer, "my:read").results.map { |r| [r.item_type, r.item_id] }
  end

  test "my:unread does not include the viewer's own notes" do
    # Authors confirm-read their own notes at creation.
    assert_empty my_search(@user, "my:unread").results
  end

  test "my:notified returns items behind undismissed due notifications" do
    viewer = add_member("Notified")

    notify(viewer, subject: @decision, read: true) # read but undismissed still shows
    notify(viewer, subject: @commitment, dismissed: true) # dismissed is gone

    reminder_note = create_note(tenant: @tenant, collective: @collective, created_by: viewer, subtype: "reminder", text: "Due reminder note")
    reminder = Notification.create!(tenant: @tenant, event: nil, notification_type: "reminder", title: "Due")
    reminder_note.update!(reminder_notification_id: reminder.id)
    NotificationRecipient.create!(notification: reminder, user: viewer, channel: "in_app", status: "delivered", tenant: @tenant)

    future = Notification.create!(tenant: @tenant, event: nil, notification_type: "reminder", title: "Future")
    future_note = create_note(tenant: @tenant, collective: @collective, created_by: viewer, subtype: "reminder", text: "Future reminder note")
    future_note.update!(reminder_notification_id: future.id)
    NotificationRecipient.create!(
      notification: future, user: viewer, channel: "in_app", status: "pending", scheduled_for: 1.hour.from_now, tenant: @tenant
    )

    results = my_search(viewer, "my:notified").results.map { |r| [r.item_type, r.item_id] }
    assert_equal [["Decision", @decision.id], ["Note", reminder_note.id]].sort, results.sort
  end

  test "my:notified resolves comment notifications to the thread root" do
    viewer = add_member("Commented At")
    comment = create_note(
      tenant: @tenant, collective: @collective, created_by: @user, commentable: @note, text: "A reply mentioning you"
    )
    notify(viewer, subject: comment)

    results = my_search(viewer, "my:notified").results.map { |r| [r.item_type, r.item_id] }
    assert_equal [["Note", @note.id]], results
  end

  test "my: filters warn and match nothing for anonymous viewers" do
    search = SearchQuery.new(tenant: @tenant, collective: nil, current_user: nil, raw_query: "my:notified cycle:all")

    assert_empty search.results
    assert search.warnings.any? { |w| w.include?("my:") }, "expected a warning about my: requiring sign-in"
  end

  test "negated my:read excludes items the viewer has confirmed read" do
    viewer = add_member("Skimmer")
    @note.confirm_read!(viewer)

    results = my_search(viewer, "-my:read").results.map { |r| [r.item_type, r.item_id] }
    assert_not_includes results, ["Note", @note.id]
    assert_includes results, ["Decision", @decision.id]
  end
end
