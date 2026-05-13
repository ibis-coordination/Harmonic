# typed: false

require "test_helper"

class HardDeleteExpiredRecordsJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Collective.clear_thread_scope
    Tenant.current_id = nil
  end

  # Helper: build a soft-deleted note whose hard_delete_after is in the past.
  def expired_soft_deleted_note(tenant: @tenant, collective: @collective, user: @user, title: "Expired")
    note = create_note(tenant: tenant, collective: collective, created_by: user, title: title, text: "body")
    note.soft_delete!(by: user)
    note.update_columns(hard_delete_after: 1.hour.ago)
    note
  end

  test "tombstones notes whose hard_delete_after has passed" do
    note = expired_soft_deleted_note

    Tenant.current_id = nil
    HardDeleteExpiredRecordsJob.perform_now

    note.reload
    assert_not_nil note.tombstoned_at, "expired note should be tombstoned"
    raw = Note.connection.select_one(
      "SELECT title, text FROM notes WHERE id = #{Note.connection.quote(note.id)}"
    )
    assert_nil raw["title"]
    assert_nil raw["text"]
  end

  test "leaves notes with hard_delete_after in the future alone" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    note.soft_delete!(by: @user)
    # hard_delete_after default is 30 days out — still in the future.

    Tenant.current_id = nil
    HardDeleteExpiredRecordsJob.perform_now

    note.reload
    assert_nil note.tombstoned_at, "future-expiring note must not be tombstoned"
    assert_equal "[deleted]", note.title, "accessor masking still applies"
  end

  test "skips notes that are already tombstoned" do
    note = expired_soft_deleted_note
    tombstoned_at = 2.days.ago
    note.update_columns(tombstoned_at: tombstoned_at, title: nil, text: nil)

    Tenant.current_id = nil
    HardDeleteExpiredRecordsJob.perform_now

    note.reload
    # Pre-existing tombstoned_at must not be overwritten by a fresh timestamp.
    assert_in_delta tombstoned_at, note.tombstoned_at, 1.second
  end

  test "leaves live (non-deleted) notes alone even if hard_delete_after is somehow set" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    # Pathological state — deleted_at nil, hard_delete_after set. Job should
    # only process rows where deleted_at IS NOT NULL.
    note.update_columns(hard_delete_after: 1.hour.ago)

    Tenant.current_id = nil
    HardDeleteExpiredRecordsJob.perform_now

    note.reload
    assert_nil note.tombstoned_at
    assert_not_nil note.title, "live note's content must not be nulled"
  end

  test "tombstones eligible notes across multiple tenants" do
    other_tenant = create_tenant(subdomain: "tenant2-#{SecureRandom.hex(4)}")
    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com", name: "Other #{SecureRandom.hex(4)}")
    other_tenant.add_user!(other_user)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, name: "Other", handle: "other-#{SecureRandom.hex(4)}")
    other_collective.add_user!(other_user)
    Tenant.current_id = other_tenant.id
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)
    other_note = expired_soft_deleted_note(tenant: other_tenant, collective: other_collective, user: other_user, title: "OtherT")
    # Restore primary tenant scope.
    Tenant.current_id = @tenant.id
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    first_note = expired_soft_deleted_note

    Tenant.current_id = nil
    Collective.clear_thread_scope
    HardDeleteExpiredRecordsJob.perform_now

    assert_not_nil first_note.reload.tombstoned_at
    assert_not_nil other_note.reload.tombstoned_at
  end

  test "one failing record does not block the rest of the batch" do
    note_a = expired_soft_deleted_note(title: "A")
    note_b = expired_soft_deleted_note(title: "B")
    fail_for_id = note_a.id

    stub = ->(note:) {
      raise StandardError, "boom" if note.id == fail_for_id
      note.update_columns(title: nil, text: nil, table_data: nil, tombstoned_at: Time.current)
    }

    DataDeletionManager.stub(:system_tombstone_note!, stub) do
      Tenant.current_id = nil
      HardDeleteExpiredRecordsJob.perform_now
    end

    assert_nil note_a.reload.tombstoned_at, "the failing note must not be tombstoned"
    assert_not_nil note_b.reload.tombstoned_at, "the sibling note must still be tombstoned"
  end
end
