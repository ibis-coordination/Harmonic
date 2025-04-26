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

  test "Note requires a title" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    note = Note.new(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      text: "This is a test note without a title."
    )

    assert_not note.valid?
    assert_includes note.errors[:title], "can't be blank"
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
end
