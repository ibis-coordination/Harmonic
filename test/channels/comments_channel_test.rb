# typed: false
require "test_helper"

class CommentsChannelTest < ActionCable::Channel::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Resource",
      text: "A commentable resource"
    )

    stub_connection(current_user: @user)
  end

  test "subscribes to a resource in a collective the user belongs to" do
    subscribe(commentable_type: "Note", commentable_id: @note.id)

    assert subscription.confirmed?
    assert_has_stream_for @note
  end

  test "rejects subscription for a user who is not a member of the collective" do
    other_user = create_user(email: "outsider-#{SecureRandom.hex(4)}@example.com")
    stub_connection(current_user: other_user)

    subscribe(commentable_type: "Note", commentable_id: @note.id)

    assert subscription.rejected?
  end

  test "subscribes to any Commentable resource, not just Note" do
    decision = create_decision(collective: @collective, created_by: @user, question: "Q?")

    subscribe(commentable_type: "Decision", commentable_id: decision.id)

    assert subscription.confirmed?
    assert_has_stream_for decision
  end

  test "rejects a commentable_type whose model does not include Commentable" do
    subscribe(commentable_type: "User", commentable_id: @user.id)

    assert subscription.rejected?
  end

  test "rejects a commentable_type that is not an application model" do
    subscribe(commentable_type: "Object", commentable_id: @note.id)

    assert subscription.rejected?
  end

  test "rejects subscription with a nonexistent commentable_id" do
    subscribe(commentable_type: "Note", commentable_id: SecureRandom.uuid)

    assert subscription.rejected?
  end

  test "rejects subscription with a nil commentable_id" do
    subscribe(commentable_type: "Note", commentable_id: nil)

    assert subscription.rejected?
  end
end
