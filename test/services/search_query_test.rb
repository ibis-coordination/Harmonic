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
    # Reindex the note with new indexer (stores "text" subtype)
    SearchIndexer.reindex(@note)
    comment = @note.add_comment(text: "This is a comment", created_by: @user)
    SearchIndexer.reindex(comment)

    search = SearchQuery.new(
      tenant: @tenant, collective: @collective, current_user: @user,
      raw_query: "type:note -subtype:comment cycle:all"
    )

    results = search.results
    # Should include regular notes (subtype is "text")
    assert_includes results.pluck(:item_id), @note.id
    # Should exclude comments
    assert_not_includes results.pluck(:item_id), comment.id
    # All results should have non-comment subtype
    assert results.none? { |r| r.subtype == "comment" }
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

  # scope: operator tests

  test "scope:public restricts search to main collective only" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user)
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public main content")
    SearchIndexer.reindex(main_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "scope:public cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    assert_includes result_ids, main_note.id
    # Should NOT include items from non-main collectives
    assert_not_includes result_ids, @note.id
  end

  test "scope:private returns only workspace content" do
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
      raw_query: "scope:private cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    assert_includes result_ids, workspace_note.id
    assert_not_includes result_ids, main_note.id
    assert_not_includes result_ids, @note.id
  end

  test "scope:shared returns non-public non-workspace content" do
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
      raw_query: "scope:shared cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    # Should include shared collective content
    assert_includes result_ids, @note.id
    # Should NOT include public or workspace content
    assert_not_includes result_ids, main_note.id
    assert_not_includes result_ids, workspace_note.id
  end

  test "-scope:private excludes workspace content" do
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
      raw_query: "-scope:private cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    # Should include public and shared content
    assert_includes result_ids, main_note.id
    assert_includes result_ids, @note.id
    # Should NOT include workspace content
    assert_not_includes result_ids, workspace_note.id
  end

  test "-scope:public excludes main collective content" do
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
      raw_query: "-scope:public cycle:all"
    )

    result_ids = search.results.pluck(:item_id)
    # Should include shared and workspace content
    assert_includes result_ids, @note.id
    assert_includes result_ids, workspace_note.id
    # Should NOT include public content
    assert_not_includes result_ids, main_note.id
  end

  test "scope:public for unauthenticated user returns main collective results" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_note = create_note(tenant: @tenant, collective: main_collective, created_by: @user, text: "public unauthenticated content")
    SearchIndexer.reindex(main_note)

    search = SearchQuery.new(
      tenant: @tenant, current_user: nil,
      raw_query: "scope:public cycle:all"
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
end
