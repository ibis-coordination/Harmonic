require "test_helper"

class ApiHelperDeleteTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @other_user = create_user
    # Set up collective membership for other_user
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: @other_user)
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )
  end

  def build_helper(user:, resource: nil)
    ApiHelper.new(
      current_user: user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_note: resource.is_a?(Note) ? resource : nil,
      current_decision: resource.is_a?(Decision) ? resource : nil,
      current_commitment: resource.is_a?(Commitment) ? resource : nil,
      request: OpenStruct.new(remote_ip: "127.0.0.1"),
    )
  end

  # --- Note deletion ---

  test "delete_note soft deletes a note by its creator" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user,
                       title: "My Note", text: "Content here")

    build_helper(user: @user, resource: note).delete_note

    note.reload
    assert note.deleted?
    assert_equal "[deleted]", note.text
    assert_equal @user.id, note.deleted_by_id
  end

  test "delete_note by creator does not log to security audit" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    log_file = Rails.root.join("log/security_audit.log")
    line_count_before = File.exist?(log_file) ? File.readlines(log_file).size : 0

    build_helper(user: @user, resource: note).delete_note

    new_lines = File.exist?(log_file) ? File.readlines(log_file).drop(line_count_before) : []
    content_deleted_entries = new_lines.select { |l| l.include?("content_deleted") && l.include?(note.id) }
    assert_empty content_deleted_entries, "Should not log content_deleted for self-deletion"
  end

  test "delete_note by collective admin logs to security audit" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @other_user,
                       title: "Flagged Note", text: "Bad content")
    admin_member = CollectiveMember.find_by(tenant: @tenant, collective: @collective, user: @user)
    admin_member.add_role!("admin")
    @user.reload

    log_file = Rails.root.join("log/security_audit.log")
    line_count_before = File.exist?(log_file) ? File.readlines(log_file).size : 0

    build_helper(user: @user, resource: note).delete_note

    note.reload
    assert note.deleted?

    new_lines = File.readlines(log_file).drop(line_count_before)
    content_deleted_entries = new_lines.select { |l| l.include?("content_deleted") }
    assert_equal 1, content_deleted_entries.size

    entry = JSON.parse(content_deleted_entries.first)
    assert_equal "Flagged Note", entry.dig("snapshot", "title")
    assert_equal "Bad content", entry.dig("snapshot", "text")
  end

  test "delete_note raises error for non-creator non-admin" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    assert_raises(ActiveRecord::RecordInvalid) do
      build_helper(user: @other_user, resource: note).delete_note
    end

    note.reload
    assert_not note.deleted?
  end

  # --- Decision deletion ---

  test "delete_decision soft deletes a decision by its creator" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user,
                               question: "Should we?", description: "Details")

    build_helper(user: @user, resource: decision).delete_decision

    decision.reload
    assert decision.deleted?
    assert_equal "[deleted]", decision.question
    assert_equal "[deleted]", decision.description
  end

  test "delete_decision raises error for non-creator non-admin" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    assert_raises(ActiveRecord::RecordInvalid) do
      build_helper(user: @other_user, resource: decision).delete_decision
    end
  end

  # --- Commitment deletion ---

  test "delete_commitment soft deletes a commitment by its creator" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user,
                                   title: "Do thing", description: "Details")

    build_helper(user: @user, resource: commitment).delete_commitment

    commitment.reload
    assert commitment.deleted?
    assert_equal "[deleted]", commitment.title
    assert_equal "[deleted]", commitment.description
  end

  test "delete_commitment raises error for non-creator non-admin" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    assert_raises(ActiveRecord::RecordInvalid) do
      build_helper(user: @other_user, resource: commitment).delete_commitment
    end
  end

  # --- Comment deletion (note that is a comment) ---

  test "delete_note works for comments and preserves parent" do
    parent_note = create_note(tenant: @tenant, collective: @collective, created_by: @other_user)
    comment = create_note(tenant: @tenant, collective: @collective, created_by: @user,
                          text: "My comment", commentable: parent_note)

    build_helper(user: @user, resource: comment).delete_note

    comment.reload
    assert comment.deleted?
    assert_equal "[deleted]", comment.text

    parent_note.reload
    assert_not parent_note.deleted?
  end
end
