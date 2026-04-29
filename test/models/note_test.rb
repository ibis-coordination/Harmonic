require "test_helper"

class NoteTest < ActiveSupport::TestCase
  # Note: create_tenant, create_user, create_collective helpers are inherited from test_helper.rb

  test "Note.create works" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    assert note.persisted?
    assert_equal "Test Note", note.title
    assert_equal "This is a test note.", note.text
    assert_equal tenant, note.tenant
    assert_equal collective, note.collective
    assert_equal user, note.created_by
    assert_equal user, note.updated_by
  end

  test "Note creates a history event on creation" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    history_event = note.note_history_events.first
    assert history_event.present?
    assert_equal "create", history_event.event_type
    assert_equal note, history_event.note
    assert_equal collective, history_event.collective
    assert_equal user, history_event.user
    assert_equal note.created_at, history_event.happened_at
  end

  test "Note creates a history event on update" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    note.update!(text: "Updated text", updated_by: user)

    history_event = note.note_history_events.last
    assert history_event.present?
    assert_equal "update", history_event.event_type
    assert_equal note, history_event.note
    assert_equal collective, history_event.collective
    assert_equal user, history_event.user
    assert_equal note.updated_at, history_event.happened_at
  end

  test "Note.confirm_read! creates a read confirmation event" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    confirmation_event = note.confirm_read!(user)
    assert confirmation_event.present?
    assert_equal "read_confirmation", confirmation_event.event_type
    assert_equal note, confirmation_event.note
    assert_equal collective, confirmation_event.collective
    assert_equal user, confirmation_event.user
  end

  test "Note.user_has_read? returns true if user has read the note" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    note.confirm_read!(user)
    assert note.user_has_read?(user)
  end

  test "Note.user_has_read? returns false if user has not read the note" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    assert_not note.user_has_read?(user)
  end

  test "Note.api_json includes expected fields" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    json = note.api_json
    assert_equal note.id, json[:id]
    assert_equal note.title, json[:title]
    assert_equal note.text, json[:text]
    assert_equal note.created_at, json[:created_at]
    assert_equal note.updated_at, json[:updated_at]
    assert_equal note.created_by_id, json[:created_by_id]
    assert_equal note.updated_by_id, json[:updated_by_id]
  end

  # === Deadline Tests ===

  test "Note with deadline in the future is open" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "deadline-collective-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Future Deadline Note",
      text: "This note has a future deadline.",
      deadline: 1.week.from_now
    )

    assert note.deadline > Time.current
  end

  test "Note with deadline in the past is closed" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "past-deadline-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Past Deadline Note",
      text: "This note has a past deadline.",
      deadline: 1.day.ago
    )

    assert note.deadline < Time.current
  end

  # === Pin Tests ===

  test "Note can be pinned" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "pin-collective-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Pinnable Note",
      text: "This note can be pinned."
    )

    note.pin!(tenant: tenant, collective: collective, user: user)
    assert note.is_pinned?(tenant: tenant, collective: collective, user: user)
  end

  test "Note can be unpinned" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "unpin-collective-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Unpinnable Note",
      text: "This note can be unpinned."
    )

    note.pin!(tenant: tenant, collective: collective, user: user)
    note.unpin!(tenant: tenant, collective: collective, user: user)
    assert_not note.is_pinned?(tenant: tenant, collective: collective, user: user)
  end

  # === Link Tests ===

  test "Note can have backlinks" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "link-collective-#{SecureRandom.hex(4)}")

    note1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note 1",
      text: "First note"
    )

    note2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note 2",
      text: "Second note"
    )

    Link.create!(
      tenant: tenant,
      collective: collective,
      from_linkable: note1,
      to_linkable: note2
    )

    # Note2 should have note1 as a backlink
    assert_includes note2.backlinks, note1
    assert_equal 1, note2.backlink_count
  end

  # === Multiple History Events ===

  test "Multiple updates create multiple history events" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "history-collective-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "History Note",
      text: "Original text"
    )

    note.update!(text: "First update", updated_by: user)
    note.update!(text: "Second update", updated_by: user)
    note.update!(text: "Third update", updated_by: user)

    # 1 create + 3 updates = 4 events
    assert_equal 4, note.note_history_events.count
  end

  # === Comment Threading Tests ===

  test "all_descendants returns empty array for note with no replies" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "descendants-empty-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note without replies",
      text: "This note has no comments"
    )

    assert_equal [], note.all_descendants
  end

  test "all_descendants returns direct replies" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "descendants-direct-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Parent Note",
      text: "This is the parent note"
    )

    reply1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "First reply",
      subtype: "comment",
      commentable: note
    )

    reply2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second reply",
      subtype: "comment",
      commentable: note
    )

    descendants = note.all_descendants
    assert_equal 2, descendants.length
    assert_includes descendants.map(&:id), reply1.id
    assert_includes descendants.map(&:id), reply2.id
  end

  test "all_descendants returns deeply nested replies" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "descendants-deep-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Root Note",
      text: "This is the root note"
    )

    # Level 1: direct reply
    level1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Level 1 reply",
      subtype: "comment",
      commentable: note
    )

    # Level 2: reply to level1
    level2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Level 2 reply",
      subtype: "comment",
      commentable: level1
    )

    # Level 3: reply to level2
    level3 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Level 3 reply",
      subtype: "comment",
      commentable: level2
    )

    # Level 4: reply to level3
    level4 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Level 4 reply",
      subtype: "comment",
      commentable: level3
    )

    descendants = note.all_descendants
    assert_equal 4, descendants.length
    assert_includes descendants.map(&:id), level1.id
    assert_includes descendants.map(&:id), level2.id
    assert_includes descendants.map(&:id), level3.id
    assert_includes descendants.map(&:id), level4.id
  end

  test "all_descendants returns replies in chronological order" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "descendants-chrono-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Parent Note",
      text: "This is the parent note"
    )

    # Create replies with explicit timestamps to ensure order
    reply1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "First reply (oldest)",
      subtype: "comment",
      commentable: note,
      created_at: 3.hours.ago
    )

    reply2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second reply (middle)",
      subtype: "comment",
      commentable: note,
      created_at: 2.hours.ago
    )

    reply3 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Third reply (newest)",
      subtype: "comment",
      commentable: note,
      created_at: 1.hour.ago
    )

    descendants = note.all_descendants
    assert_equal [reply1.id, reply2.id, reply3.id], descendants.map(&:id)
  end

  test "all_descendants does not return unrelated notes" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "descendants-unrelated-#{SecureRandom.hex(4)}")

    note1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note 1",
      text: "First note"
    )

    note2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note 2",
      text: "Second note (unrelated)"
    )

    # Reply to note1
    reply_to_note1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reply to note 1",
      subtype: "comment",
      commentable: note1
    )

    # Reply to note2
    reply_to_note2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reply to note 2",
      subtype: "comment",
      commentable: note2
    )

    descendants_of_note1 = note1.all_descendants
    assert_equal 1, descendants_of_note1.length
    assert_includes descendants_of_note1.map(&:id), reply_to_note1.id
    assert_not_includes descendants_of_note1.map(&:id), reply_to_note2.id
    assert_not_includes descendants_of_note1.map(&:id), note2.id
  end

  test "all_descendants respects tenant isolation" do
    tenant1 = create_tenant(subdomain: "tenant1-#{SecureRandom.hex(4)}")
    tenant2 = create_tenant(subdomain: "tenant2-#{SecureRandom.hex(4)}")
    user = create_user

    collective1 = create_collective(tenant: tenant1, created_by: user, handle: "studio1-#{SecureRandom.hex(4)}")
    collective2 = create_collective(tenant: tenant2, created_by: user, handle: "studio2-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant1,
      collective: collective1,
      created_by: user,
      updated_by: user,
      title: "Note in tenant 1",
      text: "This note is in tenant 1"
    )

    # Reply in tenant1 (should be included)
    reply_tenant1 = Note.create!(
      tenant: tenant1,
      collective: collective1,
      created_by: user,
      updated_by: user,
      text: "Reply in tenant 1",
      subtype: "comment",
      commentable: note
    )

    # Manually create a note in tenant2 with same commentable_id (edge case)
    # This should NOT be returned because it's in a different tenant
    Note.create!(
      tenant: tenant2,
      collective: collective2,
      created_by: user,
      updated_by: user,
      text: "Note in tenant 2",
      subtype: "comment",
      commentable_id: note.id,
      commentable_type: "Note"
    )

    descendants = note.all_descendants
    assert_equal 1, descendants.length
    assert_equal reply_tenant1.id, descendants.first.id
  end

  # === comments_with_threads Tests (Commentable concern) ===

  test "comments_with_threads returns empty hash for resource with no comments" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "threads-empty-#{SecureRandom.hex(4)}")

    # Create a standalone note (not a comment)
    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note with no comments",
      text: "This note has no comments"
    )

    result = note.comments_with_threads
    assert_equal [], result[:top_level]
    assert_equal({}, result[:threads])
  end

  test "comments_with_threads returns top-level comments with empty threads" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "threads-top-only-#{SecureRandom.hex(4)}")

    # Create a standalone note
    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note with comments",
      text: "This note has comments"
    )

    # Create top-level comments (no replies)
    comment1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "First comment",
      subtype: "comment",
      commentable: note
    )

    comment2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second comment",
      subtype: "comment",
      commentable: note
    )

    result = note.comments_with_threads
    assert_equal 2, result[:top_level].length
    assert_includes result[:top_level].map(&:id), comment1.id
    assert_includes result[:top_level].map(&:id), comment2.id
    assert_equal [], result[:threads][comment1.id]
    assert_equal [], result[:threads][comment2.id]
  end

  test "comments_with_threads returns threads with nested replies" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "threads-nested-#{SecureRandom.hex(4)}")

    # Create a standalone note
    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note with threaded comments",
      text: "This note has threaded comments"
    )

    # Create a top-level comment
    top_level = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Top level comment",
      subtype: "comment",
      commentable: note
    )

    # Create a reply to the top-level comment
    reply1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reply to top level",
      subtype: "comment",
      commentable: top_level
    )

    # Create a nested reply (reply to the reply)
    nested_reply = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Nested reply",
      subtype: "comment",
      commentable: reply1
    )

    result = note.comments_with_threads
    assert_equal 1, result[:top_level].length
    assert_equal top_level.id, result[:top_level].first.id

    # All descendants should be flattened in the thread
    thread = result[:threads][top_level.id]
    assert_equal 2, thread.length
    assert_includes thread.map(&:id), reply1.id
    assert_includes thread.map(&:id), nested_reply.id
  end

  test "comments_with_threads returns comments in chronological order" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "threads-chrono-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Note with chronological comments",
      text: "This note has chronological comments"
    )

    # Create comments with explicit timestamps
    comment1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "First comment (oldest)",
      subtype: "comment",
      commentable: note,
      created_at: 3.hours.ago
    )

    comment2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second comment (middle)",
      subtype: "comment",
      commentable: note,
      created_at: 2.hours.ago
    )

    comment3 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Third comment (newest)",
      subtype: "comment",
      commentable: note,
      created_at: 1.hour.ago
    )

    result = note.comments_with_threads
    assert_equal [comment1.id, comment2.id, comment3.id], result[:top_level].map(&:id)
  end

  # === preload_for_display Tests ===

  test "preload_for_display loads created_by association" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "preload-test-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "Test content"
    )

    # Get a fresh collection that hasn't loaded associations
    notes = Note.where(id: note.id).to_a

    # Preload for display
    Note.preload_for_display(notes)

    # Check that created_by is loaded (accessing it shouldn't trigger a query)
    assert notes.first.association(:created_by).loaded?
  end

  # === confirm_read memoization clearing test ===

  test "confirm_read clears memoized confirmed_reads count" do
    tenant = create_tenant
    user1 = create_user
    user2 = create_user(name: "Second User")
    collective = create_collective(tenant: tenant, created_by: user1, handle: "memo-test-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user1,
      updated_by: user1,
      title: "Test Note",
      text: "Test content"
    )

    # First, get the initial count (should be 0)
    assert_equal 0, note.confirmed_reads

    # Confirm read as user1
    note.confirm_read!(user1)

    # The memoized value should be cleared, so this should return 1
    assert_equal 1, note.confirmed_reads

    # Confirm read as user2
    note.confirm_read!(user2)

    # The memoized value should be cleared again, so this should return 2
    assert_equal 2, note.confirmed_reads
  end

  # Subtype tests

  test "Note defaults to text subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Default subtype note",
    )

    assert_equal "text", note.subtype
    assert note.is_text?
    assert_not note.is_reminder?
    assert_not note.is_table?
  end

  test "Note can be created with explicit subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    (Note::SUBTYPES - ["comment"]).each do |subtype|
      attrs = {
        tenant: tenant,
        collective: collective,
        created_by: user,
        updated_by: user,
        text: "#{subtype} note",
        subtype: subtype,
      }
      if subtype == "table"
        attrs[:table_data] = { "columns" => [], "rows" => [] }
      end

      note = Note.create!(attrs)
      assert_equal subtype, note.subtype
    end
  end

  test "Note comment rejects non-comment subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    parent = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Parent note",
    )

    comment = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "This is a comment",
      subtype: "reminder",
      commentable: parent,
    )

    assert_not comment.valid?
    assert_includes comment.errors[:subtype], "must be comment for comments"
  end

  test "Note comment must have comment subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    parent = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Parent note",
    )

    comment = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "This is a comment",
      subtype: "comment",
      commentable: parent,
    )

    assert comment.valid?
  end

  test "Non-comment note cannot have comment subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Not a comment",
      subtype: "comment",
    )

    assert_not note.valid?
    assert note.errors[:subtype].any?
  end

  test "comment subtype is valid" do
    assert_includes Note::SUBTYPES, "comment"
  end

  # === Text validation tests ===

  test "Note rejects nil text" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: nil,
    )

    assert_not note.valid?
    assert note.errors[:text].any?
  end

  test "Note rejects empty string text" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "",
    )

    assert_not note.valid?
    assert note.errors[:text].any?
  end

  test "Note rejects whitespace-only text" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "   \n  ",
    )

    assert_not note.valid?
    assert note.errors[:text].any?
  end

  test "Note allows blank text for table subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      subtype: "table",
      title: "Test table",
      text: "",
      table_data: { "columns" => [{ "name" => "Col", "type" => "text" }], "rows" => [] },
    )

    assert note.valid?
  end

  test "Note rejects invalid subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Invalid subtype note",
      subtype: "invalid",
    )

    assert_not note.valid?
    assert_includes note.errors[:subtype], "is not included in the list"
  end

  test "Note api_json includes subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "API json note",
      subtype: "reminder",
    )

    json = note.api_json
    assert_equal "reminder", json[:subtype]
  end

  # Edit access tests

  test "edit_access defaults to owner" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)
    note = Note.create!(tenant: tenant, collective: collective, created_by: user, updated_by: user, text: "test")

    assert_equal "owner", note.edit_access
  end

  test "user_can_edit_content? returns true for any user when edit_access is members" do
    tenant = create_tenant
    user = create_user
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(tenant: tenant, collective: collective, created_by: user, updated_by: user, text: "test", edit_access: "members")

    assert note.user_can_edit_content?(other_user)
  end

  test "user_can_edit_content? returns false for non-owner when edit_access is owner" do
    tenant = create_tenant
    user = create_user
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.create!(tenant: tenant, collective: collective, created_by: user, updated_by: user, text: "test", edit_access: "owner")

    assert_not note.user_can_edit_content?(other_user)
    assert note.user_can_edit_content?(user)
  end

  test "edit_access rejects invalid values" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    note = Note.new(tenant: tenant, collective: collective, created_by: user, updated_by: user, text: "test", edit_access: "invalid")
    assert_not note.valid?
    assert_includes note.errors[:edit_access], "is not included in the list"
  end

  # Table note validation tests

  test "table note requires table_data to be present" do
    note = Note.new(
      tenant_id: Tenant.current_id,
      collective_id: Collective.current_id,
      created_by: @global_user,
      updated_by: @global_user,
      subtype: "table",
      title: "No table data",
      text: "",
      table_data: nil,
    )

    assert_not note.valid?
    assert note.errors[:table_data].any? { |e| e.include?("must be present") }
  end

  test "table note rejects more than 20 columns" do
    columns = (1..21).map { |i| { "name" => "Col#{i}", "type" => "text" } }

    note = Note.new(
      tenant_id: Tenant.current_id,
      collective_id: Collective.current_id,
      created_by: @global_user,
      updated_by: @global_user,
      subtype: "table",
      title: "Too many columns",
      text: "",
      table_data: { "columns" => columns, "rows" => [] },
    )

    assert_not note.valid?
    assert note.errors[:table_data].any? { |e| e.include?("20 columns") }
  end

  test "table note rejects duplicate column names" do
    note = Note.new(
      tenant_id: Tenant.current_id,
      collective_id: Collective.current_id,
      created_by: @global_user,
      updated_by: @global_user,
      subtype: "table",
      title: "Duplicate columns",
      text: "",
      table_data: {
        "columns" => [
          { "name" => "Status", "type" => "text" },
          { "name" => "Status", "type" => "text" },
        ],
        "rows" => [],
      },
    )

    assert_not note.valid?
    assert note.errors[:table_data].any? { |e| e.include?("unique") }
  end

  test "table note rejects column names starting with underscore" do
    note = Note.new(
      tenant_id: Tenant.current_id,
      collective_id: Collective.current_id,
      created_by: @global_user,
      updated_by: @global_user,
      subtype: "table",
      title: "Reserved column",
      text: "",
      table_data: {
        "columns" => [{ "name" => "_id", "type" => "text" }],
        "rows" => [],
      },
    )

    assert_not note.valid?
    assert note.errors[:table_data].any? { |e| e.include?("underscore") }
  end

  test "table note rejects column names with special characters" do
    note = Note.new(
      tenant_id: Tenant.current_id,
      collective_id: Collective.current_id,
      created_by: @global_user,
      updated_by: @global_user,
      subtype: "table",
      title: "Bad column name",
      text: "",
      table_data: {
        "columns" => [{ "name" => "Status<script>", "type" => "text" }],
        "rows" => [],
      },
    )

    assert_not note.valid?
    assert note.errors[:table_data].any? { |e| e.include?("invalid characters") }
  end

  test "table note rejects invalid column type" do
    note = Note.new(
      tenant_id: Tenant.current_id,
      collective_id: Collective.current_id,
      created_by: @global_user,
      updated_by: @global_user,
      subtype: "table",
      title: "Bad type",
      text: "",
      table_data: {
        "columns" => [{ "name" => "Col", "type" => "formula" }],
        "rows" => [],
      },
    )

    assert_not note.valid?
    assert note.errors[:table_data].any? { |e| e.include?("invalid column type") }
  end

  test "table note rejects cell values exceeding 1000 chars" do
    note = Note.new(
      tenant_id: Tenant.current_id,
      collective_id: Collective.current_id,
      created_by: @global_user,
      updated_by: @global_user,
      subtype: "table",
      title: "Long cell",
      text: "",
      table_data: {
        "columns" => [{ "name" => "Data", "type" => "text" }],
        "rows" => [{ "_id" => "abc1", "Data" => "x" * 1001 }],
      },
    )

    assert_not note.valid?
    assert note.errors[:table_data].any? { |e| e.include?("1000 characters") }
  end

  # Table soft delete test

  test "soft deleting a table note scrubs table_data" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)
    note = Note.create!(
      tenant: tenant, collective: collective, created_by: user, updated_by: user,
      subtype: "table", title: "Test Table", text: "",
      table_data: { "columns" => [{ "name" => "Status", "type" => "text" }], "rows" => [] },
    )
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done" }, created_by: user)

    note.soft_delete!(by: note.created_by)

    assert_equal "[deleted]", note.text
    assert_nil note.table_data
  end

  # === Reminder Note Tests ===

  test "reminder note can be created with reminder_notification_id" do
    tenant, collective, user = create_tenant_collective_user

    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    assert note.is_reminder?
    assert_equal notification.id, note.reminder_notification_id
  end

  test "reminder_notification association loads the notification" do
    tenant, collective, user = create_tenant_collective_user

    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    assert_equal notification, note.reminder_notification
  end

  test "reminder_scheduled_for returns the stored column value" do
    tenant, collective, user = create_tenant_collective_user

    scheduled_time = 1.day.from_now.in_time_zone("UTC")

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_scheduled_for: scheduled_time,
    )

    assert_in_delta scheduled_time, note.reminder_scheduled_for, 1.second
  end

  test "reminder_scheduled_for returns nil for non-reminder notes" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Regular note",
      subtype: "text",
    )

    assert_nil note.reminder_scheduled_for
  end

  test "reminder_pending? returns true for pending reminders" do
    tenant, collective, user = create_tenant_collective_user

    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    assert note.reminder_pending?
  end

  test "reminder_pending? returns false after delivery" do
    tenant, collective, user = create_tenant_collective_user

    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    # Simulate delivery
    notification.notification_recipients.each(&:mark_delivered!)

    assert_not note.reminder_pending?
  end

  test "reminder_delivered? returns true after delivery" do
    tenant, collective, user = create_tenant_collective_user

    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    assert_not note.reminder_delivered?

    notification.notification_recipients.each(&:mark_delivered!)

    assert note.reminder_delivered?
  end

  test "cancel_reminder! deletes the notification and clears the FK" do
    tenant, collective, user = create_tenant_collective_user

    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    scheduled_time = 1.day.from_now.in_time_zone("UTC")
    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: scheduled_time,
    )

    note.reminder_service.cancel!

    assert_nil note.reload.reminder_notification_id
    assert_nil Notification.find_by(id: notification.id)
    # Scheduled time is preserved after cancellation
    assert_in_delta scheduled_time, note.reminder_scheduled_for, 1.second
  end

  test "soft deleting a reminder note cancels the pending reminder" do
    tenant, collective, user = create_tenant_collective_user

    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Remember to do the thing",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note.soft_delete!(by: user)

    assert_equal "[deleted]", note.text
    assert_nil note.reminder_notification_id
    assert_nil Notification.find_by(id: notification.id)
  end

  # === Reminder Acknowledgment Tests ===

  test "acknowledge_reminder! creates a reminder_acknowledged event" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    # Simulate delivery
    notification.notification_recipients.each(&:mark_delivered!)

    event = note.reminder_service.acknowledge!(user)
    assert event.persisted?
    assert_equal "reminder_acknowledged", event.event_type
    assert_equal user, event.user
    assert_equal note, event.note
  end

  test "acknowledge_reminder! skips if already acknowledged and note not updated" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)

    note.reminder_service.acknowledge!(user)
    note.reminder_service.acknowledge!(user)

    # Should return the existing acknowledgment, not create a new one
    assert_equal 1, note.note_history_events.where(event_type: "reminder_acknowledged", user: user).count
  end

  test "acknowledge_reminder! re-acknowledges after note update" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)

    note.reminder_service.acknowledge!(user)
    note.update!(text: "Updated reminder note", updated_by: user)
    note.reminder_service.acknowledge!(user)

    assert_equal 2, note.note_history_events.where(event_type: "reminder_acknowledged", user: user).count
  end

  test "reminder_acknowledgments counts distinct users" do
    tenant, collective, user = create_tenant_collective_user
    user2 = create_user(name: "Second User", email: "user2-#{SecureRandom.hex(4)}@example.com")
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
      additional_recipients: [user2],
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)

    note.reminder_service.acknowledge!(user)
    note.reminder_service.acknowledge!(user2)

    assert_equal 2, note.reminder_service.acknowledgments
  end

  test "metric_name returns acknowledgments for delivered reminders" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)

    assert_equal "acknowledgments", note.metric_name
    assert_equal "bell", note.octicon_metric_icon_name
    assert_equal 0, note.metric_value
  end

  test "metric_name returns readers for pending reminders" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    assert_equal "readers", note.metric_name
    assert_equal "book", note.octicon_metric_icon_name
  end

  test "metric_value returns acknowledgments count for delivered reminders" do
    tenant, collective, user = create_tenant_collective_user
    user2 = create_user(name: "User 2", email: "user2-#{SecureRandom.hex(4)}@example.com")
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
      additional_recipients: [user2],
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)
    note.reminder_service.acknowledge!(user)
    note.reminder_service.acknowledge!(user2)

    assert_equal 2, note.metric_value
  end

  test "api_json includes reminder_notification_id for reminder notes" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
    )

    json = note.api_json
    assert_equal "reminder", json[:subtype]
    assert json.key?(:reminder_notification_id)
  end
end
