# typed: false

require "test_helper"

class UserItemStatusTrackingTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  # =========================================================================
  # Note read tracking (NoteHistoryEvent with read_confirmation)
  # =========================================================================

  test "creating a read_confirmation NoteHistoryEvent marks the note as read for that user" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Create a different user to read the note
    reader = create_user
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: reader)

    # Before reading, no status should exist or has_read should be false
    status_before = UserItemStatus.find_by(
      tenant_id: @tenant.id,
      user_id: reader.id,
      item_type: "Note",
      item_id: note.id
    )
    assert_nil(status_before) || refute(status_before.has_read)

    # Create read confirmation event
    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: @collective,
      note: note,
      user: reader,
      event_type: "read_confirmation",
      happened_at: Time.current
    )

    # After reading, status should exist with has_read: true
    status_after = UserItemStatus.find_by!(
      tenant_id: @tenant.id,
      user_id: reader.id,
      item_type: "Note",
      item_id: note.id
    )
    assert status_after.has_read
    assert_not_nil status_after.read_at
  end

  test "non-read_confirmation events do not create user_item_status records" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    initial_count = UserItemStatus.where(item_type: "Note", item_id: note.id).count

    # Create a non-read event
    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: @collective,
      note: note,
      user: @user,
      event_type: "update",
      happened_at: Time.current
    )

    # Should not create a new status record
    assert_equal initial_count, UserItemStatus.where(item_type: "Note", item_id: note.id).count
  end

  # =========================================================================
  # Decision vote tracking
  # =========================================================================

  test "creating a Vote marks the decision as voted for that user" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    option = create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision)

    # Create a different user to vote
    voter = create_user
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: voter)
    participant = DecisionParticipantManager.new(decision: decision, user: voter).find_or_create_participant

    # Before voting, no status should exist or has_voted should be false
    status_before = UserItemStatus.find_by(
      tenant_id: @tenant.id,
      user_id: voter.id,
      item_type: "Decision",
      item_id: decision.id
    )
    assert_nil(status_before) || refute(status_before.has_voted)

    # Create vote
    Vote.create!(
      tenant: @tenant,
      collective: @collective,
      decision: decision,
      option: option,
      decision_participant: participant,
      accepted: 1,
      preferred: 0
    )

    # After voting, status should exist with has_voted: true
    status_after = UserItemStatus.find_by!(
      tenant_id: @tenant.id,
      user_id: voter.id,
      item_type: "Decision",
      item_id: decision.id
    )
    assert status_after.has_voted
    assert_not_nil status_after.voted_at
  end

  # =========================================================================
  # Commitment participation tracking
  # =========================================================================

  test "committing to a commitment marks it as participating for that user" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    # Create a different user to participate
    participant_user = create_user
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: participant_user)

    # Before committing, no status should exist or is_participating should be false
    status_before = UserItemStatus.find_by(
      tenant_id: @tenant.id,
      user_id: participant_user.id,
      item_type: "Commitment",
      item_id: commitment.id
    )
    assert_nil(status_before) || refute(status_before.is_participating)

    # Create participant and commit
    participant = CommitmentParticipant.create!(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: participant_user,
      committed: true
    )

    # After committing, status should exist with is_participating: true
    status_after = UserItemStatus.find_by!(
      tenant_id: @tenant.id,
      user_id: participant_user.id,
      item_type: "Commitment",
      item_id: commitment.id
    )
    assert status_after.is_participating
    assert_not_nil status_after.participated_at
  end

  test "updating a participant to committed marks it as participating" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    # Create a different user to participate
    participant_user = create_user
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: participant_user)

    # Create participant without committing
    participant = CommitmentParticipant.create!(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: participant_user,
      committed: false
    )

    # Before committing, no status should exist or is_participating should be false
    status_before = UserItemStatus.find_by(
      tenant_id: @tenant.id,
      user_id: participant_user.id,
      item_type: "Commitment",
      item_id: commitment.id
    )
    assert_nil(status_before) || refute(status_before.is_participating)

    # Update to committed
    participant.update!(committed: true)

    # After committing, status should exist with is_participating: true
    status_after = UserItemStatus.find_by!(
      tenant_id: @tenant.id,
      user_id: participant_user.id,
      item_type: "Commitment",
      item_id: commitment.id
    )
    assert status_after.is_participating
    assert_not_nil status_after.participated_at
  end

  # =========================================================================
  # Creator tracking
  # =========================================================================

  test "creating a Note marks the creator as creator in user_item_status" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    status = UserItemStatus.find_by!(
      tenant_id: @tenant.id,
      user_id: @user.id,
      item_type: "Note",
      item_id: note.id
    )
    assert status.is_creator
  end

  test "creating a Decision marks the creator as creator in user_item_status" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    status = UserItemStatus.find_by!(
      tenant_id: @tenant.id,
      user_id: @user.id,
      item_type: "Decision",
      item_id: decision.id
    )
    assert status.is_creator
  end

  test "creating a Commitment marks the creator as creator in user_item_status" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    status = UserItemStatus.find_by!(
      tenant_id: @tenant.id,
      user_id: @user.id,
      item_type: "Commitment",
      item_id: commitment.id
    )
    assert status.is_creator
  end

  test "comments (Notes with commentable) create creator status" do
    parent_note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Create a comment
    comment = create_note(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Comment",
      commentable: parent_note
    )

    # Comments should create creator status (they're searchable as standalone items)
    status = UserItemStatus.find_by(
      tenant_id: @tenant.id,
      user_id: @user.id,
      item_type: "Note",
      item_id: comment.id
    )
    assert_not_nil status
    assert status.is_creator
  end
end
