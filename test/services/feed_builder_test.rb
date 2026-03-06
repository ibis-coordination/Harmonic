# typed: false

require "test_helper"

class FeedBuilderTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  test "returns empty array when no items exist" do
    feed = FeedBuilder.new(
      notes_scope: Note.where(collective_id: @collective.id),
      decisions_scope: Decision.where(collective_id: @collective.id),
      commitments_scope: Commitment.where(collective_id: @collective.id),
    ).feed_items

    assert_equal [], feed
  end

  test "merges notes, decisions, and commitments sorted by created_at desc" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "First")
    note.update_column(:created_at, 3.hours.ago)

    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user, question: "Second?")
    decision.update_column(:created_at, 2.hours.ago)

    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user, title: "Third")
    commitment.update_column(:created_at, 1.hour.ago)

    feed = FeedBuilder.new(
      notes_scope: Note.where(collective_id: @collective.id),
      decisions_scope: Decision.where(collective_id: @collective.id),
      commitments_scope: Commitment.where(collective_id: @collective.id),
    ).feed_items

    assert_equal 3, feed.size
    assert_equal "Commitment", feed[0][:type]
    assert_equal "Decision", feed[1][:type]
    assert_equal "Note", feed[2][:type]
  end

  test "excludes comment notes" do
    parent_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Parent")
    create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Comment", commentable: parent_note)

    feed = FeedBuilder.new(
      notes_scope: Note.where(collective_id: @collective.id),
      decisions_scope: Decision.where(collective_id: @collective.id),
      commitments_scope: Commitment.where(collective_id: @collective.id),
    ).feed_items

    assert_equal 1, feed.size
    assert_equal "Parent", feed[0][:item].title
  end

  test "respects limit" do
    5.times do |i|
      create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note #{i}")
    end

    feed = FeedBuilder.new(
      notes_scope: Note.where(collective_id: @collective.id),
      decisions_scope: Decision.where(collective_id: @collective.id),
      commitments_scope: Commitment.where(collective_id: @collective.id),
      limit: 3,
    ).feed_items

    assert_equal 3, feed.size
  end

  test "feed items have expected keys" do
    create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Test")

    feed = FeedBuilder.new(
      notes_scope: Note.where(collective_id: @collective.id),
      decisions_scope: Decision.where(collective_id: @collective.id),
      commitments_scope: Commitment.where(collective_id: @collective.id),
    ).feed_items

    item = feed.first
    assert_equal "Note", item[:type]
    assert_instance_of Note, item[:item]
    assert_not_nil item[:created_at]
    assert_equal @user, item[:created_by]
  end

  test "proximity ranking boosts proximate authors" do
    user2 = create_user(name: "Proximate User")
    @tenant.add_user!(user2)
    @collective.add_user!(user2)

    user3 = create_user(name: "Distant User")
    @tenant.add_user!(user3)
    @collective.add_user!(user3)

    # Both notes created at the same time
    proximate_note = create_note(tenant: @tenant, collective: @collective, created_by: user2, title: "Proximate Note")
    proximate_note.update_column(:created_at, 1.hour.ago)

    distant_note = create_note(tenant: @tenant, collective: @collective, created_by: user3, title: "Distant Note")
    distant_note.update_column(:created_at, 1.hour.ago)

    # Proximity scores: user2 is very proximate, user3 is not
    proximity_scores = {
      user2.id => 0.5,
      user3.id => 0.01,
    }

    feed = FeedBuilder.new(
      notes_scope: Note.where(collective_id: @collective.id),
      decisions_scope: Decision.where(collective_id: @collective.id),
      commitments_scope: Commitment.where(collective_id: @collective.id),
      proximity_scores: proximity_scores,
    ).feed_items

    assert_equal 2, feed.size
    assert_equal "Proximate Note", feed[0][:item].title
    assert_equal "Distant Note", feed[1][:item].title
  end

  test "proximity ranking falls back to chronological with empty scores" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Older")
    note1.update_column(:created_at, 2.hours.ago)

    note2 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Newer")
    note2.update_column(:created_at, 1.hour.ago)

    feed = FeedBuilder.new(
      notes_scope: Note.where(collective_id: @collective.id),
      decisions_scope: Decision.where(collective_id: @collective.id),
      commitments_scope: Commitment.where(collective_id: @collective.id),
      proximity_scores: {},
    ).feed_items

    assert_equal 2, feed.size
    assert_equal "Newer", feed[0][:item].title
    assert_equal "Older", feed[1][:item].title
  end

  test "works with tenant_scoped_only for cross-collective queries" do
    # Create a second collective with its own note
    collective2 = create_collective(tenant: @tenant, created_by: @user, name: "Second", handle: "second")
    collective2.add_user!(@user)

    create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "In First")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: collective2.handle)
    create_note(tenant: @tenant, collective: collective2, created_by: @user, title: "In Second")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # Query across both collectives using tenant_scoped_only
    feed = FeedBuilder.new(
      notes_scope: Note.tenant_scoped_only(@tenant.id).where(collective_id: [@collective.id, collective2.id]),
      decisions_scope: Decision.tenant_scoped_only(@tenant.id).where(collective_id: [@collective.id, collective2.id]),
      commitments_scope: Commitment.tenant_scoped_only(@tenant.id).where(collective_id: [@collective.id, collective2.id]),
    ).feed_items

    assert_equal 2, feed.size
    titles = feed.map { |item| item[:item].title }
    assert_includes titles, "In First"
    assert_includes titles, "In Second"
  end
end
