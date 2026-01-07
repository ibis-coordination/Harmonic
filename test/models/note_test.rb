require "test_helper"

class NoteTest < ActiveSupport::TestCase
  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
    User.create!(email: email, name: name, user_type: user_type)
  end

  def create_studio(tenant:, created_by:, name: "Test Studio", handle: "test-studio")
    Studio.create!(tenant: tenant, created_by: created_by, name: name, handle: handle)
  end

  test "Note.create works" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    assert note.persisted?
    assert_equal "Test Note", note.title
    assert_equal "This is a test note.", note.text
    assert_equal tenant, note.tenant
    assert_equal studio, note.studio
    assert_equal user, note.created_by
    assert_equal user, note.updated_by
  end

  test "Note creates a history event on creation" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    history_event = note.note_history_events.first
    assert history_event.present?
    assert_equal "create", history_event.event_type
    assert_equal note, history_event.note
    assert_equal studio, history_event.studio
    assert_equal user, history_event.user
    assert_equal note.created_at, history_event.happened_at
  end

  test "Note creates a history event on update" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      studio: studio,
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
    assert_equal studio, history_event.studio
    assert_equal user, history_event.user
    assert_equal note.updated_at, history_event.happened_at
  end

  test "Note.confirm_read! creates a read confirmation event" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Test Note",
      text: "This is a test note."
    )

    confirmation_event = note.confirm_read!(user)
    assert confirmation_event.present?
    assert_equal "read_confirmation", confirmation_event.event_type
    assert_equal note, confirmation_event.note
    assert_equal studio, confirmation_event.studio
    assert_equal user, confirmation_event.user
  end

  test "Note.user_has_read? returns true if user has read the note" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      studio: studio,
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
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      studio: studio,
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
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.create!(
      tenant: tenant,
      studio: studio,
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
    studio = create_studio(tenant: tenant, created_by: user, handle: "deadline-studio-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      studio: studio,
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
    studio = create_studio(tenant: tenant, created_by: user, handle: "past-deadline-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      studio: studio,
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
    studio = create_studio(tenant: tenant, created_by: user, handle: "pin-studio-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Pinnable Note",
      text: "This note can be pinned."
    )

    note.pin!(tenant: tenant, studio: studio, user: user)
    assert note.is_pinned?(tenant: tenant, studio: studio, user: user)
  end

  test "Note can be unpinned" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user, handle: "unpin-studio-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Unpinnable Note",
      text: "This note can be unpinned."
    )

    note.pin!(tenant: tenant, studio: studio, user: user)
    note.unpin!(tenant: tenant, studio: studio, user: user)
    assert_not note.is_pinned?(tenant: tenant, studio: studio, user: user)
  end

  # === Link Tests ===

  test "Note can have backlinks" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user, handle: "link-studio-#{SecureRandom.hex(4)}")

    note1 = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Note 1",
      text: "First note"
    )

    note2 = Note.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      title: "Note 2",
      text: "Second note"
    )

    Link.create!(
      tenant: tenant,
      studio: studio,
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
    studio = create_studio(tenant: tenant, created_by: user, handle: "history-studio-#{SecureRandom.hex(4)}")

    note = Note.create!(
      tenant: tenant,
      studio: studio,
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
end
