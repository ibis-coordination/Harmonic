require "test_helper"

class UserBlockEnforcementTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)
  end

  # ==========================================
  # Comment Blocking (via ApiHelper)
  # ==========================================

  test "blocked user cannot comment on blocker's note" do
    note = create_note(text: "My note", created_by: @user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: ActionController::Parameters.new(text: "A comment"),
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.create_note(commentable: note)
    end
    assert_match(/block/, error.message)
  end

  test "blocker cannot comment on blocked user's note" do
    note = create_note(text: "Their note", created_by: @other_user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: ActionController::Parameters.new(text: "A comment"),
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.create_note(commentable: note)
    end
    assert_match(/block/, error.message)
  end

  test "unblocked user can comment normally" do
    note = create_note(text: "A note", created_by: @user)

    helper = ApiHelper.new(
      current_user: @other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: ActionController::Parameters.new(text: "A comment"),
    )

    comment = helper.create_note(commentable: note)
    assert comment.persisted?
  end

  test "blocked user cannot comment on blocker's decision" do
    decision = create_decision(question: "A question?", created_by: @user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: ActionController::Parameters.new(text: "A comment"),
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.create_note(commentable: decision)
    end
    assert_match(/block/, error.message)
  end

  test "blocked user cannot comment on blocker's commitment" do
    commitment = create_commitment(title: "A commitment", created_by: @user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: ActionController::Parameters.new(text: "A comment"),
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.create_note(commentable: commitment)
    end
    assert_match(/block/, error.message)
  end

  # ==========================================
  # Vote Blocking (via ApiHelper)
  # ==========================================

  test "blocked user cannot vote on blocker's decision" do
    decision = create_decision(question: "A question?", created_by: @user)
    creator_participant = DecisionParticipant.create!(decision: decision, user: @user, participant_uid: SecureRandom.uuid)
    option = Option.create!(decision: decision, title: "Option A", decision_participant: creator_participant)
    voter_participant = DecisionParticipant.create!(decision: decision, user: @other_user, participant_uid: SecureRandom.uuid)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      current_decision_participant: voter_participant,
      params: ActionController::Parameters.new(option_id: option.id, accepted: true),
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.vote
    end
    assert_match(/block/, error.message)
  end

  test "blocker cannot vote on blocked user's decision" do
    decision = create_decision(question: "A question?", created_by: @other_user)
    creator_participant = DecisionParticipant.create!(decision: decision, user: @other_user, participant_uid: SecureRandom.uuid)
    option = Option.create!(decision: decision, title: "Option A", decision_participant: creator_participant)
    voter_participant = DecisionParticipant.create!(decision: decision, user: @user, participant_uid: SecureRandom.uuid)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      current_decision_participant: voter_participant,
      params: ActionController::Parameters.new(option_id: option.id, accepted: true),
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.vote
    end
    assert_match(/block/, error.message)
  end

  # ==========================================
  # Join Commitment Blocking (via ApiHelper)
  # ==========================================

  test "blocked user cannot join blocker's commitment" do
    commitment = create_commitment(title: "A commitment", created_by: @user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_commitment: commitment,
      params: ActionController::Parameters.new,
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.join_commitment
    end
    assert_match(/block/, error.message)
  end

  test "blocker cannot join blocked user's commitment" do
    commitment = create_commitment(title: "A commitment", created_by: @other_user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_commitment: commitment,
      params: ActionController::Parameters.new,
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      helper.join_commitment
    end
    assert_match(/block/, error.message)
  end

  # ==========================================
  # Notification Suppression
  # ==========================================

  test "notification suppressed when recipient has blocked actor" do
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @other_user,
    )

    # Should not create notification because @user has blocked @other_user
    NotificationDispatcher.notify_user(
      event: event,
      recipient: @user,
      notification_type: "mention",
      title: "#{@other_user.name} mentioned you",
      body: "test",
      url: "/n/test",
    )

    assert_equal 0, NotificationRecipient.where(user: @user).count
  end

  test "notification delivered when no block exists" do
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @other_user,
    )

    NotificationDispatcher.notify_user(
      event: event,
      recipient: @user,
      notification_type: "mention",
      title: "#{@other_user.name} mentioned you",
      body: "test",
      url: "/n/test",
    )

    assert_operator NotificationRecipient.where(user: @user).count, :>=, 1
  end
end
