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
    collective = create_collective(tenant: tenant, created_by: user, handle: "deadline-studio-#{SecureRandom.hex(4)}")

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
    collective = create_collective(tenant: tenant, created_by: user, handle: "pin-studio-#{SecureRandom.hex(4)}")

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
    collective = create_collective(tenant: tenant, created_by: user, handle: "unpin-studio-#{SecureRandom.hex(4)}")

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
    collective = create_collective(tenant: tenant, created_by: user, handle: "link-studio-#{SecureRandom.hex(4)}")

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
    collective = create_collective(tenant: tenant, created_by: user, handle: "history-studio-#{SecureRandom.hex(4)}")

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
      commentable: note
    )

    reply2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second reply",
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
      commentable: note
    )

    # Level 2: reply to level1
    level2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Level 2 reply",
      commentable: level1
    )

    # Level 3: reply to level2
    level3 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Level 3 reply",
      commentable: level2
    )

    # Level 4: reply to level3
    level4 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Level 4 reply",
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
      commentable: note,
      created_at: 3.hours.ago
    )

    reply2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second reply (middle)",
      commentable: note,
      created_at: 2.hours.ago
    )

    reply3 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Third reply (newest)",
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
      commentable: note1
    )

    # Reply to note2
    reply_to_note2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reply to note 2",
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
      commentable: note
    )

    comment2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second comment",
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
      commentable: note
    )

    # Create a reply to the top-level comment
    reply1 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reply to top level",
      commentable: top_level
    )

    # Create a nested reply (reply to the reply)
    nested_reply = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Nested reply",
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
      commentable: note,
      created_at: 3.hours.ago
    )

    comment2 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Second comment (middle)",
      commentable: note,
      created_at: 2.hours.ago
    )

    comment3 = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Third comment (newest)",
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
end
