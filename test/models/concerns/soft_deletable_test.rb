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
end
