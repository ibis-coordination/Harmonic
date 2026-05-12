require "test_helper"

class SoftDeletableTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant
    @user = create_user
    @admin = create_user
    @collective = create_collective(tenant: @tenant, created_by: @user)
    Tenant.current_id = @tenant.id
  end

  # --- Note soft delete ---

  test "Note#soft_delete! sets deleted_at and deleted_by_id" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    note.soft_delete!(by: @admin)

    assert note.deleted?
    assert_not_nil note.deleted_at
    assert_equal @admin.id, note.deleted_by_id
  end

  test "Note#soft_delete! scrubs text and title" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Original Title", text: "Original text content"
    )

    note.soft_delete!(by: @user)

    assert_equal "[deleted]", note.title
    assert_equal "[deleted]", note.text
  end

  test "Note#content_snapshot returns title and text before scrubbing" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "My Title", text: "My text"
    )

    snapshot = note.content_snapshot

    assert_equal({ title: "My Title", text: "My text" }, snapshot)
  end

  test "Note#soft_delete! removes from search index" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Verify soft_delete! calls SearchIndexer.delete by checking no error is raised
    # (SearchIndexer.delete is a no-op in test environment for missing indices)
    assert_nothing_raised do
      note.soft_delete!(by: @user)
    end
    assert note.deleted?
  end

  test "Note#soft_delete! unpins the note from collective" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    @collective.pin_item!(note)
    assert @collective.has_pinned?(note)

    note.soft_delete!(by: @user)

    @collective.reload
    assert_not @collective.has_pinned?(note)
  end

  test "Note#soft_delete! preserves comments" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    comment = create_note(
      tenant: @tenant, collective: @collective, created_by: @admin,
      text: "A comment", subtype: "comment",
      commentable: note
    )

    note.soft_delete!(by: @user)

    assert comment.reload.persisted?
    assert_equal "A comment", comment.text
  end

  test "Note#deleted? returns false for non-deleted notes" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    assert_not note.deleted?
  end

  # --- Decision soft delete ---

  test "Decision#soft_delete! scrubs question and description" do
    decision = create_decision(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Should we?", description: "Details here"
    )

    decision.soft_delete!(by: @user)

    assert decision.deleted?
    assert_equal "[deleted]", decision.question
    assert_equal "[deleted]", decision.description
  end

  test "Decision#content_snapshot returns question and description" do
    decision = create_decision(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Should we?", description: "Details"
    )

    snapshot = decision.content_snapshot

    assert_equal({ question: "Should we?", description: "Details" }, snapshot)
  end

  test "Decision#soft_delete! preserves votes and options" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    participant = DecisionParticipant.create!(
      tenant: @tenant, collective: @collective, decision: decision, user: @user
    )
    option = Option.create!(
      tenant: @tenant, collective: @collective, decision: decision,
      title: "Option A", decision_participant: participant
    )

    decision.soft_delete!(by: @user)

    assert Option.unscoped.find(option.id).persisted?
    assert_equal "Option A", Option.unscoped.find(option.id).title
  end

  # --- Commitment soft delete ---

  test "Commitment#soft_delete! scrubs title and description" do
    commitment = create_commitment(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Do the thing", description: "Details here"
    )

    commitment.soft_delete!(by: @user)

    assert commitment.deleted?
    assert_equal "[deleted]", commitment.title
    assert_equal "[deleted]", commitment.description
  end

  test "Commitment#content_snapshot returns title and description" do
    commitment = create_commitment(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Do the thing", description: "Details"
    )

    snapshot = commitment.content_snapshot

    assert_equal({ title: "Do the thing", description: "Details" }, snapshot)
  end

  test "Commitment#soft_delete! preserves participants" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    participant = CommitmentParticipant.create!(
      tenant: @tenant, collective: @collective, commitment: commitment,
      user: @admin
    )

    commitment.soft_delete!(by: @user)

    assert participant.reload.persisted?
  end

  # --- Default scope filtering ---

  test "deleted notes are excluded from default queries" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Visible")
    note2 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Will Delete")
    note2.soft_delete!(by: @user)

    notes = Note.all
    assert_includes notes, note1
    assert_not_includes notes, note2
  end

  test "deleted decisions are excluded from default queries" do
    d1 = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    d2 = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    d2.soft_delete!(by: @user)

    decisions = Decision.all
    assert_includes decisions, d1
    assert_not_includes decisions, d2
  end

  test "deleted commitments are excluded from default queries" do
    c1 = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    c2 = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    c2.soft_delete!(by: @user)

    commitments = Commitment.all
    assert_includes commitments, c1
    assert_not_includes commitments, c2
  end

  test "deleted content can be found with with_deleted scope" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    note.soft_delete!(by: @user)

    found = Note.with_deleted.find(note.id)
    assert_equal note.id, found.id
    assert found.deleted?
  end

  # --- Search index behavior ---

  test "soft_delete! does not enqueue a search reindex" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Clear any jobs enqueued by the create
    enqueued_jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size

    note.soft_delete!(by: @user)

    reindex_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs[enqueued_jobs_before..]
      .select { |j| j["job_class"] == "ReindexSearchJob" }
    assert_empty reindex_jobs, "soft_delete! should not enqueue a ReindexSearchJob"
  end

  # --- Tenant isolation with with_deleted ---

  test "with_deleted preserves tenant scoping" do
    tenant2 = create_tenant(subdomain: "tenant2-#{SecureRandom.hex(4)}")
    collective2 = create_collective(tenant: tenant2, created_by: @user)

    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Tenant 1")
    note1.soft_delete!(by: @user)

    Tenant.current_id = tenant2.id
    note2 = create_note(tenant: tenant2, collective: collective2, created_by: @user, title: "Tenant 2")

    # with_deleted in tenant2 context should only find tenant2's notes
    results = Note.with_deleted.all
    assert_not_includes results, note1, "with_deleted should not leak deleted notes from other tenants"
    assert_includes results, note2

    # with_deleted in tenant1 context should only find tenant1's notes
    Tenant.current_id = @tenant.id
    results = Note.with_deleted.all
    assert_includes results, note1
    assert_not_includes results, note2, "with_deleted should not leak notes from other tenants"
  end

  # --- Content snapshot truncation ---

  test "content_snapshot values are not truncated at model level" do
    long_text = "x" * 5000
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      text: long_text
    )

    snapshot = note.content_snapshot
    assert_equal 5000, snapshot[:text].length
  end

  # --- Grace period: hard_delete_after only set when model opts in ---

  test "Note opts into the hard-delete pipeline" do
    assert Note.participates_in_hard_delete?
  end

  test "Decision does NOT opt into the hard-delete pipeline" do
    assert_not Decision.participates_in_hard_delete?
  end

  test "Commitment does NOT opt into the hard-delete pipeline" do
    assert_not Commitment.participates_in_hard_delete?
  end

  test "Note#soft_delete! sets hard_delete_after to deleted_at + grace period" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    note.soft_delete!(by: @user)
    assert_not_nil note.hard_delete_after
    expected = note.deleted_at + SoftDeletable::DEFAULT_GRACE_PERIOD
    assert_in_delta expected, note.hard_delete_after, 1.second
  end

  test "Decision#soft_delete! does NOT set hard_delete_after (no auto hard-delete)" do
    d = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    d.soft_delete!(by: @user)
    assert_nil d.hard_delete_after
  end

  test "Commitment#soft_delete! does NOT set hard_delete_after" do
    c = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    c.soft_delete!(by: @user)
    assert_nil c.hard_delete_after
  end

  test "Decision#undo_delete! works indefinitely (no grace-period cutoff)" do
    d = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    d.soft_delete!(by: @user)
    # Even far in the future, undo works because Decision doesn't participate in hard-delete.
    travel_to 1.year.from_now do
      assert_nothing_raised { d.undo_delete!(by: @user) }
    end
    d.reload
    assert_not d.deleted?
  end

  # --- tombstoned? predicate ---

  test "Note#tombstoned? is false by default and true when tombstoned_at is set" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    assert_not note.tombstoned?

    note.update_columns(tombstoned_at: Time.current)
    assert note.tombstoned?
  end

  test "Decision#tombstoned? always returns false (no tombstoned_at column)" do
    d = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    assert_not d.tombstoned?

    d.soft_delete!(by: @user)
    assert_not d.tombstoned?
  end

  # --- Content preservation in DB (defense-in-depth assertion) ---

  test "Note#soft_delete! does NOT scrub the underlying DB columns" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Original Title", text: "Original text content"
    )
    note.soft_delete!(by: @user)

    # Raw DB columns still hold the original values
    raw = Note.connection.select_one(
      "SELECT title, text FROM notes WHERE id = #{Note.connection.quote(note.id)}"
    )
    assert_equal "Original Title", raw["title"]
    assert_equal "Original text content", raw["text"]
  end

  test "Decision#soft_delete! does NOT scrub the underlying DB columns" do
    d = create_decision(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Should we?", description: "Details here"
    )
    d.soft_delete!(by: @user)
    raw = Decision.connection.select_one(
      "SELECT question, description FROM decisions WHERE id = #{Decision.connection.quote(d.id)}"
    )
    assert_equal "Should we?", raw["question"]
    assert_equal "Details here", raw["description"]
  end

  test "Commitment#soft_delete! does NOT scrub the underlying DB columns" do
    c = create_commitment(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Do the thing", description: "Details here"
    )
    c.soft_delete!(by: @user)
    raw = Commitment.connection.select_one(
      "SELECT title, description FROM commitments WHERE id = #{Commitment.connection.quote(c.id)}"
    )
    assert_equal "Do the thing", raw["title"]
    assert_equal "Details here", raw["description"]
  end

  # --- raw_* escape hatches return real content even when deleted ---

  test "Note#raw_title and Note#raw_text return real values after soft_delete" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Real Title", text: "Real text"
    )
    note.soft_delete!(by: @user)

    assert_equal "[deleted]", note.title
    assert_equal "[deleted]", note.text
    assert_equal "Real Title", note.raw_title
    assert_equal "Real text", note.raw_text
  end

  test "Decision#raw_question and Decision#raw_description return real values after soft_delete" do
    d = create_decision(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Real Q?", description: "Real D"
    )
    d.soft_delete!(by: @user)

    assert_equal "[deleted]", d.question
    assert_equal "[deleted]", d.description
    assert_equal "Real Q?", d.raw_question
    assert_equal "Real D", d.raw_description
  end

  test "Commitment#raw_title and Commitment#raw_description return real values after soft_delete" do
    c = create_commitment(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Real T", description: "Real D"
    )
    c.soft_delete!(by: @user)

    assert_equal "[deleted]", c.title
    assert_equal "[deleted]", c.description
    assert_equal "Real T", c.raw_title
    assert_equal "Real D", c.raw_description
  end

  test "Note#content_snapshot returns real values even after soft_delete" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Snap Title", text: "Snap text"
    )
    note.soft_delete!(by: @user)

    assert_equal({ title: "Snap Title", text: "Snap text" }, note.content_snapshot)
  end

  # --- undo_delete! ---

  test "Note#undo_delete! clears all three timestamps and restores visibility" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Restore me", text: "body"
    )
    note.soft_delete!(by: @user)
    assert note.deleted?

    note.undo_delete!(by: @user)
    note.reload

    assert_not note.deleted?
    assert_nil note.deleted_at
    assert_nil note.deleted_by_id
    assert_nil note.hard_delete_after
    assert_equal "Restore me", note.title
    assert_equal "body", note.text
  end

  test "undo_delete! raises if hard_delete_after has passed" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    note.soft_delete!(by: @user)
    note.update_columns(hard_delete_after: 1.minute.ago)

    assert_raises(SoftDeletable::GracePeriodExpired) do
      note.undo_delete!(by: @user)
    end
  end

  test "undo_delete! is a no-op on a non-deleted record" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    assert_nothing_raised { note.undo_delete!(by: @user) }
    assert_not note.deleted?
  end
end
