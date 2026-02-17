# typed: false

require "test_helper"

class SearchIndexerTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_studio_user
  end

  test "reindex creates search index for a note" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Clear any records created by callbacks
    SearchIndex.where(item_type: "Note", item_id: note.id).delete_all

    assert_difference "SearchIndex.count", 1 do
      SearchIndexer.reindex(note)
    end

    search_index = SearchIndex.find_by(item_type: "Note", item_id: note.id)
    assert_equal note.title, search_index.title
    assert_equal note.text, search_index.body
    assert_equal note.truncated_id, search_index.truncated_id
  end

  test "reindex creates search index for a decision" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    # Clear any records created by callbacks
    SearchIndex.where(item_type: "Decision", item_id: decision.id).delete_all

    assert_difference "SearchIndex.count", 1 do
      SearchIndexer.reindex(decision)
    end

    search_index = SearchIndex.find_by(item_type: "Decision", item_id: decision.id)
    assert_equal decision.question, search_index.title
    assert_equal decision.description, search_index.body
    assert_equal decision.truncated_id, search_index.truncated_id
  end

  test "reindex creates search index for a commitment" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    # Clear any records created by callbacks
    SearchIndex.where(item_type: "Commitment", item_id: commitment.id).delete_all

    assert_difference "SearchIndex.count", 1 do
      SearchIndexer.reindex(commitment)
    end

    search_index = SearchIndex.find_by(item_type: "Commitment", item_id: commitment.id)
    assert_equal commitment.title, search_index.title
    assert_equal commitment.description, search_index.body
    assert_equal commitment.truncated_id, search_index.truncated_id
  end

  test "reindex creates search index for comments with subtype and replying_to_id" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    comment = note.add_comment(text: "This is a comment", created_by: @user)

    # Clear any records created by callbacks
    SearchIndex.where(item_type: "Note", item_id: comment.id).delete_all

    assert_difference "SearchIndex.count", 1 do
      SearchIndexer.reindex(comment)
    end

    search_index = SearchIndex.find_by(item_type: "Note", item_id: comment.id)
    assert_equal "comment", search_index.subtype
    assert_equal note.created_by_id, search_index.replying_to_id
    assert_equal comment.deadline, search_index.deadline
  end

  test "reindex updates existing search index on subsequent calls" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Original Title")

    # Clear any records created by callbacks
    SearchIndex.where(item_type: "Note", item_id: note.id).delete_all
    SearchIndexer.reindex(note)

    original_search_index = SearchIndex.find_by(item_type: "Note", item_id: note.id)
    assert_equal "Original Title", original_search_index.title

    note.update!(title: "Updated Title")
    SearchIndexer.reindex(note)

    updated_search_index = SearchIndex.find_by(item_type: "Note", item_id: note.id)
    assert_equal "Updated Title", updated_search_index.title
    assert_equal original_search_index.id, updated_search_index.id
  end

  test "delete removes search index for an item" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Ensure the search index exists
    SearchIndexer.reindex(note)
    assert SearchIndex.exists?(item_type: "Note", item_id: note.id)

    SearchIndexer.delete(note)

    assert_not SearchIndex.exists?(item_type: "Note", item_id: note.id)
  end

  test "searchable_text includes option titles for decisions" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    decision.options.create!(title: "Option A", decision_participant: participant)
    decision.options.create!(title: "Option B", decision_participant: participant)

    # Clear any records created by callbacks
    SearchIndex.where(item_type: "Decision", item_id: decision.id).delete_all
    SearchIndexer.reindex(decision)

    search_index = SearchIndex.find_by(item_type: "Decision", item_id: decision.id)
    assert_includes search_index.searchable_text, "Option A"
    assert_includes search_index.searchable_text, "Option B"
  end

  test "comments are indexed separately (not included in parent searchable_text)" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    comment1 = note.add_comment(text: "First comment", created_by: @user)
    comment2 = note.add_comment(text: "Second comment", created_by: @user)

    # Clear any records created by callbacks and reindex
    SearchIndex.where(item_type: "Note").delete_all
    SearchIndexer.reindex(note)
    SearchIndexer.reindex(comment1)
    SearchIndexer.reindex(comment2)

    # Parent note's searchable_text does NOT include comment text
    parent_search_index = SearchIndex.find_by(item_type: "Note", item_id: note.id)
    assert_not_includes parent_search_index.searchable_text, "First comment"
    assert_not_includes parent_search_index.searchable_text, "Second comment"
    assert_nil parent_search_index.subtype

    # Each comment has its own search index entry
    comment1_search_index = SearchIndex.find_by(item_type: "Note", item_id: comment1.id)
    assert_includes comment1_search_index.searchable_text, "First comment"
    assert_equal "comment", comment1_search_index.subtype

    comment2_search_index = SearchIndex.find_by(item_type: "Note", item_id: comment2.id)
    assert_includes comment2_search_index.searchable_text, "Second comment"
    assert_equal "comment", comment2_search_index.subtype
  end

  test "reindex counts backlinks correctly" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 1", text: "Some text")
    note2 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 2", text: "References note1")

    # Create a link from note2 to note1 (simulating what LinkParser does with URLs)
    Link.create!(from_linkable: note2, to_linkable: note1)

    # Clear any records created by callbacks and reindex
    SearchIndex.where(item_type: "Note", item_id: note1.id).delete_all
    SearchIndexer.reindex(note1)

    search_index = SearchIndex.find_by(item_type: "Note", item_id: note1.id)
    assert_equal 1, search_index.backlink_count
  end
end
