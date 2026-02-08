# typed: false

require "test_helper"

class InvalidatesSearchIndexTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @superagent, @user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
  end

  # =========================================================================
  # NoteHistoryEvent tests - only read_confirmation events trigger reindex
  # =========================================================================

  test "creating a read_confirmation NoteHistoryEvent enqueues reindex for the note" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: note.id }]) do
      NoteHistoryEvent.create!(
        tenant: @tenant,
        superagent: @superagent,
        note: note,
        user: @user,
        event_type: "read_confirmation",
        happened_at: Time.current
      )
    end
  end

  test "creating a create NoteHistoryEvent does not enqueue reindex" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Clear any jobs enqueued during note creation
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: ReindexSearchJob) do
      NoteHistoryEvent.create!(
        tenant: @tenant,
        superagent: @superagent,
        note: note,
        user: @user,
        event_type: "create",
        happened_at: Time.current
      )
    end
  end

  test "creating an update NoteHistoryEvent does not enqueue reindex" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Clear any jobs enqueued during note creation
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: ReindexSearchJob) do
      NoteHistoryEvent.create!(
        tenant: @tenant,
        superagent: @superagent,
        note: note,
        user: @user,
        event_type: "update",
        happened_at: Time.current
      )
    end
  end

  # =========================================================================
  # Link tests - both from_linkable and to_linkable get reindexed
  # =========================================================================

  test "creating a Link enqueues reindex for both linked items" do
    note_1 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Note 1")
    note_2 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Note 2")

    # Clear any jobs enqueued during note creation
    clear_enqueued_jobs

    # Should enqueue 2 reindex jobs: one for each linked item
    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: note_1.id }]) do
      assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: note_2.id }]) do
        Link.create!(
          tenant: @tenant,
          superagent: @superagent,
          from_linkable: note_1,
          to_linkable: note_2
        )
      end
    end
  end

  test "destroying a Link enqueues reindex for both linked items" do
    note_1 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Note 1")
    note_2 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Note 2")
    link = Link.create!(
      tenant: @tenant,
      superagent: @superagent,
      from_linkable: note_1,
      to_linkable: note_2
    )

    # Clear any jobs enqueued during creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: note_1.id }]) do
      assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: note_2.id }]) do
        link.destroy!
      end
    end
  end

  # =========================================================================
  # Option tests - reindex parent decision
  # =========================================================================

  test "creating an Option enqueues reindex for the decision" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Clear any jobs enqueued during decision creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Decision", item_id: decision.id }]) do
      create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    end
  end

  test "destroying an Option enqueues reindex for the decision" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)

    # Clear any jobs enqueued during creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Decision", item_id: decision.id }]) do
      option.destroy!
    end
  end

  # =========================================================================
  # Vote tests - reindex parent decision
  # =========================================================================

  test "creating a Vote enqueues reindex for the decision" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    decision_participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant

    # Clear any jobs enqueued during setup
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Decision", item_id: decision.id }]) do
      Vote.create!(
        tenant: @tenant,
        superagent: @superagent,
        decision: decision,
        option: option,
        decision_participant: decision_participant,
        accepted: 1,
        preferred: 0
      )
    end
  end

  test "destroying a Vote enqueues reindex for the decision" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    decision_participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant,
      superagent: @superagent,
      decision: decision,
      option: option,
      decision_participant: decision_participant,
      accepted: 1,
      preferred: 0
    )

    # Clear any jobs enqueued during creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Decision", item_id: decision.id }]) do
      vote.destroy!
    end
  end

  # =========================================================================
  # CommitmentParticipant tests - reindex parent commitment
  # =========================================================================

  test "creating a CommitmentParticipant enqueues reindex for the commitment" do
    commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Clear any jobs enqueued during commitment creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Commitment", item_id: commitment.id }]) do
      CommitmentParticipant.create!(
        tenant: @tenant,
        superagent: @superagent,
        commitment: commitment,
        user: @user
      )
    end
  end

  test "updating a CommitmentParticipant enqueues reindex for the commitment" do
    commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user)
    participant = CommitmentParticipant.create!(
      tenant: @tenant,
      superagent: @superagent,
      commitment: commitment,
      user: @user
    )

    # Clear any jobs enqueued during creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Commitment", item_id: commitment.id }]) do
      participant.update!(committed: true)
    end
  end

  test "destroying a CommitmentParticipant enqueues reindex for the commitment" do
    commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user)
    participant = CommitmentParticipant.create!(
      tenant: @tenant,
      superagent: @superagent,
      commitment: commitment,
      user: @user
    )

    # Clear any jobs enqueued during creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Commitment", item_id: commitment.id }]) do
      participant.destroy!
    end
  end

  # =========================================================================
  # Note as comment tests - reindex parent commentable
  # =========================================================================

  test "creating a comment Note enqueues reindex for the parent Note" do
    parent_note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Parent Note")

    # Clear any jobs enqueued during parent creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: parent_note.id }]) do
      create_note(
        tenant: @tenant,
        superagent: @superagent,
        created_by: @user,
        title: "Comment",
        commentable: parent_note
      )
    end
  end

  test "creating a comment on a Decision enqueues reindex for the Decision" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Clear any jobs enqueued during decision creation
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Decision", item_id: decision.id }]) do
      create_note(
        tenant: @tenant,
        superagent: @superagent,
        created_by: @user,
        title: "Comment",
        commentable: decision
      )
    end
  end

  test "creating a regular Note (not a comment) does not trigger InvalidatesSearchIndex callback" do
    # A regular note (not a comment) should have search_index_items return []
    # This means InvalidatesSearchIndex won't enqueue any reindex jobs
    # (The Searchable concern will still enqueue a job for the note itself, but that's separate)
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Verify that search_index_items returns empty for a non-comment note
    assert_equal [], note.send(:search_index_items)
  end

  test "creating a comment on a non-searchable item (RepresentationSession) does not enqueue parent reindex" do
    # RepresentationSession is commentable but NOT searchable
    # Comments on it should still be indexed themselves, but should NOT trigger parent reindex
    @superagent.settings["any_member_can_represent"] = true
    @superagent.save!
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user
    )

    # Clear any jobs enqueued during session creation
    clear_enqueued_jobs

    # Creating a comment on a non-searchable item should NOT enqueue a reindex for the parent
    # (The comment itself will still be indexed via Searchable concern)
    comment = create_note(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      title: "Session comment",
      commentable: session
    )

    # Verify that search_index_items returns empty for comments on non-searchable items
    assert_equal [], comment.send(:search_index_items)
  end
end
