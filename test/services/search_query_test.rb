# typed: false

require "test_helper"

class SearchQueryTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    # For Notes, searchable_text uses body (text) only since title is derived from text
    @note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "Budget proposal details")
    @decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user, question: "Approve budget?")
    @commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Review budget")

    # Ensure search index is populated (callbacks should do this, but let's be explicit)
    SearchIndexer.reindex(@note)
    SearchIndexer.reindex(@decision)
    SearchIndexer.reindex(@commitment)
  end

  # Full-text search tests

  test "full-text search finds matching content" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { q: "budget", cycle: "all" }
    )

    results = search.results
    assert_equal 3, results.count
    assert results.all? { |r| r.title.downcase.include?("budget") || r.searchable_text.downcase.include?("budget") }
  end

  test "full-text search returns empty for non-matching query" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { q: "nonexistent", cycle: "all" }
    )

    assert_empty search.results
  end

  test "full-text search without query returns all results" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { cycle: "all" }
    )

    assert_equal 3, search.results.count
  end

  # Type filter tests

  test "type filter restricts to specified types" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { type: "note", cycle: "all" }
    )

    results = search.results
    assert results.all? { |r| r.item_type == "Note" }
    assert_equal 1, results.count
  end

  test "type filter accepts comma-separated types" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { type: "note,decision", cycle: "all" }
    )

    results = search.results
    assert results.all? { |r| %w[Note Decision].include?(r.item_type) }
    assert_equal 2, results.count
  end

  test "type=all returns all types" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { type: "all", cycle: "all" }
    )

    assert_equal 3, search.results.count
  end

  # Time window tests

  test "cycle filter restricts to time window" do
    old_note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Old note")
    old_note.update_columns(created_at: 1.month.ago, deadline: 1.month.ago + 1.day)
    SearchIndexer.reindex(old_note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { cycle: "today" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, old_note.id
  end

  test "cycle=all returns all items" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { cycle: "all" }
    )

    assert_equal 3, search.results.count
  end

  # Ownership filters

  test "mine filter returns items created by current user" do
    other_user = create_user(email: "other_mine@example.com", name: "Other Mine User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    other_note = create_note(tenant: @tenant, superagent: @superagent, created_by: other_user, title: "Other's note")
    SearchIndexer.reindex(other_note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { filters: "mine", cycle: "all" }
    )

    assert search.results.all? { |r| r.created_by_id == @user.id }
    assert_not_includes search.results.pluck(:item_id), other_note.id
  end

  test "not_mine filter excludes items created by current user" do
    other_user = create_user(email: "other_not_mine@example.com", name: "Other Not Mine User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    other_note = create_note(tenant: @tenant, superagent: @superagent, created_by: other_user, title: "Other's note")
    SearchIndexer.reindex(other_note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { filters: "not_mine", cycle: "all" }
    )

    assert search.results.none? { |r| r.created_by_id == @user.id }
    assert_includes search.results.pluck(:item_id), other_note.id
  end

  # Status filters

  test "open filter returns items with future deadlines" do
    closed_note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Closed note")
    closed_note.update_columns(deadline: 1.day.ago)
    SearchIndexer.reindex(closed_note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { filters: "open", cycle: "all" }
    )

    assert search.results.all? { |r| r.deadline > Time.current }
    assert_not_includes search.results.pluck(:item_id), closed_note.id
  end

  test "closed filter returns items with past deadlines" do
    closed_note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Closed note")
    closed_note.update_columns(deadline: 1.day.ago)
    SearchIndexer.reindex(closed_note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { filters: "closed", cycle: "all" }
    )

    assert search.results.all? { |r| r.deadline <= Time.current }
    assert_includes search.results.pluck(:item_id), closed_note.id
  end

  # Presence filters

  test "has_backlinks filter returns items with backlinks" do
    note2 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Linking note")
    Link.create!(from_linkable: note2, to_linkable: @note, tenant_id: @tenant.id, superagent_id: @superagent.id)
    SearchIndexer.reindex(@note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { filters: "has_backlinks", cycle: "all" }
    )

    assert search.results.all? { |r| r.backlink_count > 0 }
    assert_includes search.results.pluck(:item_id), @note.id
  end

  # Sorting tests

  test "sort_by=created_at-desc returns newest first" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { sort_by: "created_at-desc", cycle: "all" }
    )

    results = search.results.to_a
    created_ats = results.map(&:created_at)
    assert_equal created_ats, created_ats.sort.reverse
  end

  test "sort_by=created_at-asc returns oldest first" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { sort_by: "created_at-asc", cycle: "all" }
    )

    results = search.results.to_a
    created_ats = results.map(&:created_at)
    assert_equal created_ats, created_ats.sort
  end

  test "sort_by=relevance-desc works with text search" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { q: "budget", sort_by: "relevance-desc", cycle: "all" }
    )

    results = search.results
    # Should not raise and should return results
    assert results.respond_to?(:to_a)
  end

  # Pagination tests

  test "cursor pagination returns next page without overlap" do
    10.times do |i|
      note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Note #{i}")
      SearchIndexer.reindex(note)
    end

    search1 = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { per_page: 5, cycle: "all" }
    )

    page1_ids = search1.paginated_results.pluck(:item_id)
    cursor = search1.next_cursor

    search2 = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { per_page: 5, cursor: cursor, cycle: "all" }
    )

    page2_ids = search2.paginated_results.pluck(:item_id)

    # No overlap between pages
    assert_empty(page1_ids & page2_ids)
  end

  test "per_page is clamped to valid range" do
    search_low = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { per_page: -5, cycle: "all" }
    )
    assert_equal 25, search_low.per_page

    search_high = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { per_page: 500, cycle: "all" }
    )
    assert_equal 100, search_high.per_page
  end

  # Grouping tests

  test "grouped_results groups by item_type" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { group_by: "item_type", cycle: "all" }
    )

    grouped = search.grouped_results
    group_keys = grouped.map(&:first)

    assert_includes group_keys, "Note"
    assert_includes group_keys, "Decision"
    assert_includes group_keys, "Commitment"
  end

  test "group_by=none returns flat results" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { group_by: "none", cycle: "all" }
    )

    grouped = search.grouped_results
    assert_equal 1, grouped.length
    assert_nil grouped.first.first
  end

  test "grouped_results groups by status" do
    closed_note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Closed note")
    closed_note.update_columns(deadline: 1.day.ago)
    SearchIndexer.reindex(closed_note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { group_by: "status", cycle: "all" }
    )

    grouped = search.grouped_results
    group_keys = grouped.map(&:first)

    assert_includes group_keys, "open"
    assert_includes group_keys, "closed"
  end

  # Multi-tenancy tests

  test "results are scoped to tenant and superagent" do
    other_tenant = create_tenant(subdomain: "other")
    other_user = create_user(email: "other_tenant@example.com")
    other_tenant.add_user!(other_user)
    other_superagent = create_superagent(tenant: other_tenant, created_by: other_user, handle: "other-studio")
    other_note = create_note(tenant: other_tenant, superagent: other_superagent, created_by: other_user, title: "Other tenant note")
    SearchIndexer.reindex(other_note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { cycle: "all" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, other_note.id
  end

  # to_params tests

  test "to_params returns query parameters" do
    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
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
      tenant: @tenant, superagent: @superagent, current_user: @user,
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
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { q: "test" }
    )
    assert search_with_query.sort_by_options.any? { |opt| opt[1] == "relevance-desc" }

    search_without_query = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: {}
    )
    assert search_without_query.sort_by_options.none? { |opt| opt[1] == "relevance-desc" }
  end

  # Exact phrase matching tests

  test "exact phrase matches consecutive substring" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "Budget proposal review")
    SearchIndexer.reindex(note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      raw_query: '"Budget proposal"',
      params: { cycle: "all" }
    )

    assert_includes search.results.pluck(:item_id), note.id
  end

  test "exact phrase does NOT match different word order" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "proposal Budget")
    SearchIndexer.reindex(note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      raw_query: '"Budget proposal"',
      params: { cycle: "all" }
    )

    # Should NOT include the note because word order is different
    assert_not_includes search.results.pluck(:item_id), note.id
  end

  test "exact phrase does NOT match words in different positions" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "more search testing")
    SearchIndexer.reindex(note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      raw_query: '"testing more"',
      params: { cycle: "all" }
    )

    # Should NOT include the note because "testing more" is not a consecutive substring
    assert_not_includes search.results.pluck(:item_id), note.id
  end

  # Excluded terms tests

  test "excluded term filters out matching results" do
    note_with_term = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "apple banana")
    note_without_term = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "apple cherry")
    SearchIndexer.reindex(note_with_term)
    SearchIndexer.reindex(note_without_term)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      raw_query: "apple -banana",
      params: { cycle: "all" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, note_with_term.id
    assert_includes result_ids, note_without_term.id
  end

  test "multiple excluded terms filter correctly" do
    note1 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "apple banana")
    note2 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "apple cherry")
    note3 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, text: "apple date")
    SearchIndexer.reindex(note1)
    SearchIndexer.reindex(note2)
    SearchIndexer.reindex(note3)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      raw_query: "apple -banana -cherry",
      params: { cycle: "all" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_not_includes result_ids, note1.id
    assert_not_includes result_ids, note2.id
    assert_includes result_ids, note3.id
  end

  # Tenant-wide search tests

  test "tenant-wide search includes items from scenes (public)" do
    # Create a scene
    scene = Superagent.create!(
      tenant: @tenant, created_by: @user,
      name: "Public Scene", handle: "public-scene",
      superagent_type: "scene"
    )
    scene_note = create_note(tenant: @tenant, superagent: scene, created_by: @user, text: "scene content")
    SearchIndexer.reindex(scene_note)

    # Tenant-wide search (no superagent specified)
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      params: { cycle: "all" }
    )

    assert_includes search.results.pluck(:item_id), scene_note.id
  end

  test "tenant-wide search includes items from studios user is member of" do
    # Create a studio and add user as member
    studio = Superagent.create!(
      tenant: @tenant, created_by: @user,
      name: "Member Studio", handle: "member-studio",
      superagent_type: "studio"
    )
    studio.add_user!(@user)
    studio_note = create_note(tenant: @tenant, superagent: studio, created_by: @user, text: "studio member content")
    SearchIndexer.reindex(studio_note)

    # Tenant-wide search
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      params: { cycle: "all" }
    )

    assert_includes search.results.pluck(:item_id), studio_note.id
  end

  test "tenant-wide search excludes items from studios user is NOT member of" do
    # Create another user who owns a studio
    other_user = User.create!(name: "Other User", email: "other-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)

    # Create a private studio that @user is NOT a member of
    private_studio = Superagent.create!(
      tenant: @tenant, created_by: other_user,
      name: "Private Studio", handle: "private-studio",
      superagent_type: "studio"
    )
    private_studio.add_user!(other_user)
    private_note = create_note(tenant: @tenant, superagent: private_studio, created_by: other_user, text: "private studio content")
    SearchIndexer.reindex(private_note)

    # Tenant-wide search as @user (who is NOT a member of private_studio)
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      params: { cycle: "all" }
    )

    assert_not_includes search.results.pluck(:item_id), private_note.id
  end

  test "tenant-wide search combines scenes and member studios" do
    # Create a scene
    scene = Superagent.create!(
      tenant: @tenant, created_by: @user,
      name: "Test Scene", handle: "test-scene-combo",
      superagent_type: "scene"
    )
    scene_note = create_note(tenant: @tenant, superagent: scene, created_by: @user, text: "scene combo")
    SearchIndexer.reindex(scene_note)

    # Create a studio user is member of
    member_studio = Superagent.create!(
      tenant: @tenant, created_by: @user,
      name: "Member Studio", handle: "member-studio-combo",
      superagent_type: "studio"
    )
    member_studio.add_user!(@user)
    studio_note = create_note(tenant: @tenant, superagent: member_studio, created_by: @user, text: "studio combo")
    SearchIndexer.reindex(studio_note)

    # Create another user's private studio
    other_user = User.create!(name: "Other", email: "other-combo-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    private_studio = Superagent.create!(
      tenant: @tenant, created_by: other_user,
      name: "Private", handle: "private-combo",
      superagent_type: "studio"
    )
    private_studio.add_user!(other_user)
    private_note = create_note(tenant: @tenant, superagent: private_studio, created_by: other_user, text: "private combo")
    SearchIndexer.reindex(private_note)

    # Tenant-wide search
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      raw_query: "combo",
      params: { cycle: "all" }
    )

    result_ids = search.results.pluck(:item_id)
    assert_includes result_ids, scene_note.id, "Should include scene items"
    assert_includes result_ids, studio_note.id, "Should include member studio items"
    assert_not_includes result_ids, private_note.id, "Should exclude non-member studio items"
  end

  # Security: explicit superagent access control

  test "search with explicit superagent the user has NO access to returns no results" do
    # Create another user who owns a private studio
    other_user = User.create!(name: "Studio Owner", email: "owner-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)

    private_studio = Superagent.create!(
      tenant: @tenant, created_by: other_user,
      name: "Private Studio", handle: "private-explicit",
      superagent_type: "studio"
    )
    private_studio.add_user!(other_user)
    private_note = create_note(tenant: @tenant, superagent: private_studio, created_by: other_user, text: "secret content")
    SearchIndexer.reindex(private_note)

    # Attempt to search with explicit superagent the user does NOT have access to
    # This simulates a malicious or buggy caller passing a superagent without checking access
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      superagent: private_studio,
      params: { cycle: "all" }
    )

    # Should return NO results because user doesn't have access to this studio
    assert_empty search.results.pluck(:item_id), "Should not expose items from studios user has no access to"
  end

  test "search with explicit superagent the user HAS access to returns results" do
    # Create a studio and add user as member
    member_studio = Superagent.create!(
      tenant: @tenant, created_by: @user,
      name: "Member Studio", handle: "member-explicit",
      superagent_type: "studio"
    )
    member_studio.add_user!(@user)
    studio_note = create_note(tenant: @tenant, superagent: member_studio, created_by: @user, text: "accessible content")
    SearchIndexer.reindex(studio_note)

    # Search with explicit superagent the user has access to
    search = SearchQuery.new(
      tenant: @tenant, current_user: @user,
      superagent: member_studio,
      params: { cycle: "all" }
    )

    assert_includes search.results.pluck(:item_id), studio_note.id
  end

  test "search with explicit scene returns results for any user" do
    # Scenes are public, so anyone can search them
    scene = Superagent.create!(
      tenant: @tenant, created_by: @user,
      name: "Public Scene", handle: "public-explicit",
      superagent_type: "scene"
    )
    scene_note = create_note(tenant: @tenant, superagent: scene, created_by: @user, text: "public content")
    SearchIndexer.reindex(scene_note)

    # Different user searching the scene
    other_user = User.create!(name: "Random User", email: "random-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)

    search = SearchQuery.new(
      tenant: @tenant, current_user: other_user,
      superagent: scene,
      params: { cycle: "all" }
    )

    assert_includes search.results.pluck(:item_id), scene_note.id
  end
end
