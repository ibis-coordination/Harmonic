# typed: false

require "test_helper"

class SearchIndexTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_studio_user
  end

  test "creates search index record with valid attributes" do
    search_index = SearchIndex.new(
      tenant: @tenant,
      collective: @collective,
      item_type: "Note",
      item_id: SecureRandom.uuid,
      truncated_id: "abc12345",
      title: "Test Note",
      body: "Test body content",
      searchable_text: "Test Note Test body content",
      created_at: Time.current,
      updated_at: Time.current,
      deadline: 1.day.from_now,
      created_by: @user,
      updated_by: @user,
    )

    assert search_index.valid?
  end

  test "validates item_type inclusion" do
    search_index = SearchIndex.new(
      tenant: @tenant,
      collective: @collective,
      item_type: "InvalidType",
      item_id: SecureRandom.uuid,
      truncated_id: "abc12345",
      title: "Test",
      searchable_text: "Test",
      deadline: 1.day.from_now,
    )

    assert_not search_index.valid?
    assert_includes search_index.errors[:item_type], "is not included in the list"
  end

  test "is_open returns true when deadline is in the future" do
    search_index = SearchIndex.new(deadline: 1.day.from_now)
    assert search_index.is_open
  end

  test "is_open returns false when deadline is in the past" do
    search_index = SearchIndex.new(deadline: 1.day.ago)
    assert_not search_index.is_open
  end

  test "status returns 'open' when deadline is in the future" do
    search_index = SearchIndex.new(deadline: 1.day.from_now)
    assert_equal "open", search_index.status
  end

  test "status returns 'closed' when deadline is in the past" do
    search_index = SearchIndex.new(deadline: 1.day.ago)
    assert_equal "closed", search_index.status
  end

  test "path returns correct path for Note" do
    search_index = SearchIndex.new(
      collective: @collective,
      item_type: "Note",
      truncated_id: "abc12345",
    )

    assert_equal "#{@collective.path}/n/abc12345", search_index.path
  end

  test "path returns correct path for Decision" do
    search_index = SearchIndex.new(
      collective: @collective,
      item_type: "Decision",
      truncated_id: "abc12345",
    )

    assert_equal "#{@collective.path}/d/abc12345", search_index.path
  end

  test "path returns correct path for Commitment" do
    search_index = SearchIndex.new(
      collective: @collective,
      item_type: "Commitment",
      truncated_id: "abc12345",
    )

    assert_equal "#{@collective.path}/c/abc12345", search_index.path
  end

  test "date grouping helpers return correct formats" do
    search_index = SearchIndex.new(
      created_at: Time.zone.parse("2024-06-15 10:30:00"),
      deadline: Time.zone.parse("2024-07-20 15:00:00"),
    )

    assert_equal "2024-06-15", search_index.date_created
    assert_match(/2024-W\d{2}/, search_index.week_created)
    assert_equal "2024-06", search_index.month_created
    assert_equal "2024-07-20", search_index.date_deadline
    assert_match(/2024-W\d{2}/, search_index.week_deadline)
    assert_equal "2024-07", search_index.month_deadline
  end

  test "api_json returns expected hash" do
    search_index = SearchIndex.new(
      tenant: @tenant,
      collective: @collective,
      item_type: "Note",
      item_id: SecureRandom.uuid,
      truncated_id: "abc12345",
      title: "Test Note",
      body: "Test body",
      created_at: Time.current,
      updated_at: Time.current,
      deadline: 1.day.from_now,
      backlink_count: 5,
      link_count: 3,
      participant_count: 10,
      voter_count: 0,
      option_count: 0,
      comment_count: 2,
    )

    json = search_index.api_json

    assert_equal "Note", json[:item_type]
    assert_equal "abc12345", json[:truncated_id]
    assert_equal "Test Note", json[:title]
    assert_equal "Test body", json[:body]
    assert_equal 5, json[:backlink_count]
    assert_equal 3, json[:link_count]
    assert_equal 10, json[:participant_count]
    assert_equal 2, json[:comment_count]
    assert json[:is_open]
  end
end
