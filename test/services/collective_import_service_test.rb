# typed: false

require "test_helper"
require "zip"

class CollectiveImportServiceTest < ActiveSupport::TestCase
  setup do
    @shared_email = "shared-#{SecureRandom.hex(6)}@example.com"

    # Source: create tenant, collective, user, and populate with data
    @source_tenant = create_tenant(subdomain: "source-#{SecureRandom.hex(4)}", name: "Source Tenant")
    @source_user = create_user(email: @shared_email, name: "Source User")
    @source_tenant.add_user!(@source_user)
    @source_collective = create_collective(tenant: @source_tenant, created_by: @source_user, name: "Test Collective", handle: "test-col-#{SecureRandom.hex(4)}")
    @source_collective.add_user!(@source_user)
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    @source_note = create_note(tenant: @source_tenant, collective: @source_collective, created_by: @source_user, title: "Import Test Note", text: "Some content")
    @source_decision = create_decision(tenant: @source_tenant, collective: @source_collective, created_by: @source_user)
    @source_option = create_option(decision: @source_decision, created_by: @source_user, title: "Option A")
    @source_participant = DecisionParticipantManager.new(decision: @source_decision, user: @source_user).find_or_create_participant
    @source_vote = Vote.create!(tenant: @source_tenant, collective: @source_collective, decision: @source_decision, option: @source_option, decision_participant: @source_participant, accepted: 1, preferred: 1)
    @source_commitment = create_commitment(tenant: @source_tenant, collective: @source_collective, created_by: @source_user)
    @source_cp = CommitmentParticipant.create!(tenant: @source_tenant, collective: @source_collective, commitment: @source_commitment, user: @source_user, committed_at: Time.current)

    # Export the source collective
    @export = DataExport.create!(tenant: @source_tenant, collective: @source_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: @export).perform!
    @export.reload

    # Target: different tenant, same user email (to test matching)
    @target_tenant = create_tenant(subdomain: "target-#{SecureRandom.hex(4)}", name: "Target Tenant")
    @target_tenant.add_user!(@source_user) # Same user exists in target tenant

    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope

    @data_import = DataImport.create!(
      tenant: @target_tenant,
      user: @source_user,
      status: "pending",
    )
    @data_import.file.attach(
      io: StringIO.new(@export.file.download),
      filename: "import.zip",
      content_type: "application/zip",
    )
  end

  test "imports collective with correct name and handle" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    assert_equal "completed", @data_import.status
    assert @data_import.collective_id.present?

    imported_collective = Collective.find(@data_import.collective_id)
    assert_equal @source_collective.name, imported_collective.name
    assert_equal @source_collective.handle, imported_collective.handle
  end

  test "matches existing users by email" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)

    # The source_user should be a member of the imported collective (matched by email)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)
    members = CollectiveMember.where(collective_id: imported_collective.id)
    member_user_ids = members.pluck(:user_id)
    assert_includes member_user_ids, @source_user.id

    # user_mapping should show them as matched
    mapping = @data_import.user_mapping
    matched_entry = mapping[@source_user.email]
    assert matched_entry.present?
    assert_equal true, matched_entry["matched"]
  end

  test "creates placeholder users for unmatched emails" do
    unmatched_email = "unmatched-#{SecureRandom.hex(6)}@example.com"

    # Create a second user in the source collective with a unique email that doesn't exist in target
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    second_user = create_user(email: unmatched_email, name: "Unmatched User")
    @source_tenant.add_user!(second_user)
    @source_collective.add_user!(second_user)
    create_note(tenant: @source_tenant, collective: @source_collective, created_by: second_user, title: "Unmatched Note")

    # Re-export with the new user
    export2 = DataExport.create!(tenant: @source_tenant, collective: @source_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: export2).perform!
    export2.reload

    # Delete the second user so they won't match on import
    # (simulate importing into a fresh instance where this user doesn't exist)
    second_user.update!(email: "deleted-#{SecureRandom.hex(6)}@example.com")

    # Import into target
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    import2 = DataImport.create!(tenant: @target_tenant, user: @source_user, status: "pending")
    import2.file.attach(io: StringIO.new(export2.file.download), filename: "import2.zip", content_type: "application/zip")

    service = CollectiveImportService.new(data_import: import2)
    service.perform!

    import2.reload
    placeholder = User.find_by(email: unmatched_email)
    assert_not_nil placeholder, "Expected a placeholder user with email #{unmatched_email}"
    assert_equal "imported_placeholder", placeholder.user_type
  end

  test "imports notes with correct content" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    notes = Note.where(collective_id: imported_collective.id)
    assert_equal 1, notes.count
    assert_equal "Import Test Note", notes.first.title
    assert_equal "Some content", notes.first.text
    # ID should be different from source
    assert_not_equal @source_note.id, notes.first.id
  end

  test "imports decisions with options and votes" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    decisions = Decision.where(collective_id: imported_collective.id)
    assert_equal 1, decisions.count

    decision = decisions.first
    options = Option.where(decision_id: decision.id)
    assert_equal 1, options.count
    assert_equal "Option A", options.first.title

    votes = Vote.where(decision_id: decision.id)
    assert_equal 1, votes.count
    assert_equal 1, votes.first.accepted
    assert_equal 1, votes.first.preferred
  end

  test "imports commitments with participants" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    commitments = Commitment.where(collective_id: imported_collective.id)
    assert_equal 1, commitments.count

    participants = CommitmentParticipant.where(commitment_id: commitments.first.id)
    assert_equal 1, participants.count
    assert participants.first.committed_at.present?
  end

  test "preserves original timestamps" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    note = Note.where(collective_id: imported_collective.id).first
    # Timestamps should match source (within 1 second to account for serialization rounding)
    assert_in_delta @source_note.created_at.to_f, note.created_at.to_f, 1.0
  end

  test "imports note history events" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    note = Note.where(collective_id: imported_collective.id).first
    events = NoteHistoryEvent.where(note_id: note.id)
    assert events.count >= 1
    assert_equal "create", events.first.event_type
  end

  test "sets record_counts on data_import" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    assert_equal 1, @data_import.record_counts["notes"]
    assert_equal 1, @data_import.record_counts["decisions"]
    assert_equal 1, @data_import.record_counts["commitments"]
  end

  test "marks import as failed on error" do
    # Corrupt the ZIP
    @data_import.file.attach(io: StringIO.new("not a zip"), filename: "bad.zip", content_type: "application/zip")

    service = CollectiveImportService.new(data_import: @data_import)
    assert_raises { service.perform! }

    @data_import.reload
    assert_equal "failed", @data_import.status
    assert @data_import.error_message.present?
  end

  test "stores user_mapping on data_import" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    mapping = @data_import.user_mapping
    assert mapping.is_a?(Hash)
    assert mapping.values.any? { |v| v["matched"] == true }
  end

  test "imports comments with correct commentable reference" do
    # Add a comment on the source decision
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    comment = create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "A comment", text: "Comment body", commentable: @source_decision,
    )

    # Re-export with the comment
    export2 = DataExport.create!(tenant: @source_tenant, collective: @source_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: export2).perform!
    export2.reload

    # Import into target
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    import2 = DataImport.create!(tenant: @target_tenant, user: @source_user, status: "pending")
    import2.file.attach(io: StringIO.new(export2.file.download), filename: "import2.zip", content_type: "application/zip")

    CollectiveImportService.new(data_import: import2).perform!
    import2.reload

    imported_collective = Collective.find(import2.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    # Should have 2 notes: the original note + the comment
    notes = Note.where(collective_id: imported_collective.id)
    assert_equal 2, notes.count, "Expected 2 notes (1 text + 1 comment), got #{notes.count}"

    imported_comment = notes.find_by(subtype: "comment")
    assert_not_nil imported_comment, "Comment was not imported"
    assert_equal "A comment", imported_comment.title
    assert_equal "Decision", imported_comment.commentable_type

    # The commentable_id should point to the imported decision (not the source)
    imported_decision = Decision.where(collective_id: imported_collective.id).first
    assert_equal imported_decision.id, imported_comment.commentable_id
  end

  # --- Note subtype tests ---

  test "imports statement notes with correct statementable reference" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    statement = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Final statement", text: "We decided X", subtype: "statement",
      statementable_type: "Decision", statementable_id: @source_decision.id,
    )

    data_import, imported_collective = export_and_import_source!

    notes = Note.where(collective_id: imported_collective.id, subtype: "statement")
    assert_equal 1, notes.count
    imported_statement = notes.first
    assert_equal "Final statement", imported_statement.title
    assert_equal "Decision", imported_statement.statementable_type
    imported_decision = Decision.where(collective_id: imported_collective.id).first
    assert_equal imported_decision.id, imported_statement.statementable_id
  end

  test "imports table notes with table_data" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    table_data = {
      "columns" => [{ "name" => "Name", "type" => "text" }, { "name" => "Score", "type" => "number" }],
      "rows" => [{ "Name" => "Alice", "Score" => "10" }, { "Name" => "Bob", "Score" => "8" }],
    }
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Score Table", text: "", subtype: "table", table_data: table_data,
    )

    data_import, imported_collective = export_and_import_source!

    table_note = Note.where(collective_id: imported_collective.id, subtype: "table").first
    assert_not_nil table_note
    assert_equal "Score Table", table_note.title
    assert_equal table_data, table_note.table_data
  end

  test "imports reminder notes with reminder_scheduled_for" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    reminder_time = 3.days.from_now.change(usec: 0)
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Reminder", text: "Don't forget", subtype: "reminder",
      reminder_scheduled_for: reminder_time, deadline: reminder_time,
    )

    data_import, imported_collective = export_and_import_source!

    reminder = Note.where(collective_id: imported_collective.id, subtype: "reminder").first
    assert_not_nil reminder
    assert_equal "Reminder", reminder.title
  end

  test "imports comments on commitments" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Commitment comment", text: "Looking good", subtype: "comment",
      commentable_type: "Commitment", commentable_id: @source_commitment.id,
    )

    data_import, imported_collective = export_and_import_source!

    comment = Note.where(collective_id: imported_collective.id, subtype: "comment").first
    assert_not_nil comment
    assert_equal "Commitment", comment.commentable_type
    imported_commitment = Commitment.where(collective_id: imported_collective.id).first
    assert_equal imported_commitment.id, comment.commentable_id
  end

  test "imports nested comments (comment on a comment)" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    parent_comment = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Parent comment", text: "First", subtype: "comment",
      commentable_type: "Decision", commentable_id: @source_decision.id,
    )
    # Comment on the comment (commentable_type: "Note")
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Reply", text: "Agree", subtype: "comment",
      commentable_type: "Note", commentable_id: parent_comment.id,
    )

    data_import, imported_collective = export_and_import_source!

    comments = Note.where(collective_id: imported_collective.id, subtype: "comment").order(:created_at)
    assert_equal 2, comments.count

    parent = comments.first
    reply = comments.second
    assert_equal "Decision", parent.commentable_type
    assert_equal "Note", reply.commentable_type
    # Reply's commentable_id should point to the imported parent comment
    assert_equal parent.id, reply.commentable_id
  end

  # --- Decision subtype tests ---

  test "imports lottery decisions with beacon data" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    lottery = Decision.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "Lottery pick?", subtype: "lottery",
      deadline: 1.week.from_now, options_open: false,
      lottery_beacon_round: 12345, lottery_beacon_randomness: "abc123def456",
    )

    data_import, imported_collective = export_and_import_source!

    imported_lottery = Decision.where(collective_id: imported_collective.id, subtype: "lottery").first
    assert_not_nil imported_lottery
    assert_equal 12345, imported_lottery.lottery_beacon_round
    assert_equal "abc123def456", imported_lottery.lottery_beacon_randomness
    # audit_chain_hash should be cleared for imported decisions
    assert_nil imported_lottery.audit_chain_hash
  end

  test "imports executive decisions with decision_maker" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    Decision.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "Executive call?", subtype: "executive",
      deadline: 1.week.from_now, options_open: false, decision_maker_id: @source_user.id,
    )

    data_import, imported_collective = export_and_import_source!

    imported_exec = Decision.where(collective_id: imported_collective.id, subtype: "executive").first
    assert_not_nil imported_exec
    assert_equal "Executive call?", imported_exec.question
    # decision_maker_id should be remapped to the matched user
    assert imported_exec.decision_maker_id.present?
  end

  # --- Invites ---

  test "imports active invites with new codes" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    original_code = "original123"
    Invite.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      code: original_code, expires_at: 1.week.from_now,
    )

    data_import, imported_collective = export_and_import_source!

    invites = Invite.where(collective_id: imported_collective.id)
    assert_equal 1, invites.count
    # Code should be regenerated, not preserved from source
    assert_not_equal original_code, invites.first.code
  end

  # --- Archived members and soft-deleted content ---

  test "imports archived members preserving archived_at" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    second_user = create_user(name: "Archived User")
    @source_tenant.add_user!(second_user)
    member = @source_collective.add_user!(second_user)
    member.update!(archived_at: 1.day.ago)

    data_import, imported_collective = export_and_import_source!

    members = CollectiveMember.where(collective_id: imported_collective.id)
    archived = members.select { |m| m.archived_at.present? }
    assert_equal 1, archived.count
  end

  test "imports soft-deleted decisions" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    deleted_decision = create_decision(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "Deleted decision?",
    )
    deleted_decision.soft_delete!(by: @source_user)

    data_import, imported_collective = export_and_import_source!

    all_decisions = Decision.with_deleted.where(collective_id: imported_collective.id)
    deleted = all_decisions.select { |d| d.deleted_at.present? }
    assert_equal 1, deleted.count
    assert_equal "[deleted]", deleted.first.question # Content was scrubbed by soft_delete!
  end

  test "imports soft-deleted commitments" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    deleted_commitment = create_commitment(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Deleted commitment",
    )
    deleted_commitment.soft_delete!(by: @source_user)

    data_import, imported_collective = export_and_import_source!

    all_commitments = Commitment.with_deleted.where(collective_id: imported_collective.id)
    deleted = all_commitments.select { |c| c.deleted_at.present? }
    assert_equal 1, deleted.count
  end

  # --- Comment/statement coverage for all types ---

  test "imports comments on representation sessions" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    session = RepresentationSession.create!(
      tenant: @source_tenant, collective: @source_collective,
      representative_user_id: @source_user.id,
      began_at: 1.hour.ago, confirmed_understanding: true,
    )
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Session comment", text: "Good session", subtype: "comment",
      commentable_type: "RepresentationSession", commentable_id: session.id,
    )

    data_import, imported_collective = export_and_import_source!

    comment = Note.where(collective_id: imported_collective.id, subtype: "comment").first
    assert_not_nil comment
    assert_equal "RepresentationSession", comment.commentable_type
    imported_session = RepresentationSession.where(collective_id: imported_collective.id).first
    assert_equal imported_session.id, comment.commentable_id
  end

  test "imports statements on commitments" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Commitment statement", text: "We did it", subtype: "statement",
      statementable_type: "Commitment", statementable_id: @source_commitment.id,
    )

    data_import, imported_collective = export_and_import_source!

    statement = Note.where(collective_id: imported_collective.id, subtype: "statement").first
    assert_not_nil statement
    assert_equal "Commitment", statement.statementable_type
    imported_commitment = Commitment.where(collective_id: imported_collective.id).first
    assert_equal imported_commitment.id, statement.statementable_id
  end

  test "imports 3-deep nested comments" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    level1 = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Level 1", text: "Top comment", subtype: "comment",
      commentable_type: "Decision", commentable_id: @source_decision.id,
    )
    level2 = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Level 2", text: "Reply", subtype: "comment",
      commentable_type: "Note", commentable_id: level1.id,
    )
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Level 3", text: "Reply to reply", subtype: "comment",
      commentable_type: "Note", commentable_id: level2.id,
    )

    data_import, imported_collective = export_and_import_source!

    comments = Note.where(collective_id: imported_collective.id, subtype: "comment").order(:created_at)
    assert_equal 3, comments.count

    imported_l1 = comments[0]
    imported_l2 = comments[1]
    imported_l3 = comments[2]

    # L1 -> Decision
    assert_equal "Decision", imported_l1.commentable_type
    imported_decision = Decision.where(collective_id: imported_collective.id).first
    assert_equal imported_decision.id, imported_l1.commentable_id

    # L2 -> L1 (Note)
    assert_equal "Note", imported_l2.commentable_type
    assert_equal imported_l1.id, imported_l2.commentable_id

    # L3 -> L2 (Note)
    assert_equal "Note", imported_l3.commentable_type
    assert_equal imported_l2.id, imported_l3.commentable_id
  end

  test "imports deeply nested comments regardless of database ordering" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    # Create a chain: Decision -> L1 -> L2 -> L3 -> L4 -> L5
    parent = @source_decision
    parent_type = "Decision"
    levels = []
    5.times do |i|
      comment = Note.create!(
        tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
        title: "Level #{i + 1}", text: "Depth #{i + 1}", subtype: "comment",
        commentable_type: parent_type, commentable_id: parent.id,
      )
      levels << comment
      parent = comment
      parent_type = "Note"
    end

    data_import, imported_collective = export_and_import_source!

    comments = Note.where(collective_id: imported_collective.id, subtype: "comment")
    assert_equal 5, comments.count, "All 5 levels should be imported"

    # Build a lookup by title
    by_title = comments.index_by(&:title)

    # Verify the chain is intact
    imported_decision = Decision.where(collective_id: imported_collective.id).first
    l1 = by_title["Level 1"]
    assert_equal "Decision", l1.commentable_type
    assert_equal imported_decision.id, l1.commentable_id

    (2..5).each do |i|
      comment = by_title["Level #{i}"]
      parent = by_title["Level #{i - 1}"]
      assert_equal "Note", comment.commentable_type
      assert_equal parent.id, comment.commentable_id,
        "Level #{i} should point to Level #{i - 1}"
    end
  end

  test "imports comments correctly when child appears before parent in export JSON" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    parent_comment = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Parent", text: "First", subtype: "comment",
      commentable_type: "Decision", commentable_id: @source_decision.id,
    )
    child_comment = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Child", text: "Reply", subtype: "comment",
      commentable_type: "Note", commentable_id: parent_comment.id,
    )

    # Export normally
    export = DataExport.create!(tenant: @source_tenant, collective: @source_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: export).perform!
    export.reload

    # Manipulate the ZIP: reverse the comment order in notes.json so child appears first
    zip_data = T.unsafe(export.file).download
    files = {}
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        next if entry.directory?
        files[entry.name] = io.read
      end
    end

    # Find and reorder notes.json
    notes_key = files.keys.find { |k| k.end_with?("notes.json") }
    notes = JSON.parse(files[notes_key])
    comments = notes.select { |n| n["subtype"] == "comment" }
    non_comments = notes.reject { |n| n["subtype"] == "comment" }
    # Put child first, then parent (reverse of creation order)
    reversed_comments = comments.reverse
    files[notes_key] = JSON.pretty_generate(non_comments + reversed_comments)

    # Rebuild the ZIP
    new_zip = StringIO.new
    Zip::OutputStream.write_buffer(new_zip) do |zos|
      files.each do |name, content|
        zos.put_next_entry(name)
        zos.write(content)
      end
    end
    new_zip.rewind

    # Import the manipulated ZIP
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    data_import = DataImport.create!(tenant: @target_tenant, user: @source_user, status: "pending")
    data_import.file.attach(io: new_zip, filename: "reversed.zip", content_type: "application/zip")
    CollectiveImportService.new(data_import: data_import).perform!
    data_import.reload

    imported_collective = Collective.unscoped.find(data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    comments = Note.where(collective_id: imported_collective.id, subtype: "comment")
    assert_equal 2, comments.count

    imported_parent = comments.find_by(title: "Parent")
    imported_child = comments.find_by(title: "Child")

    assert_not_nil imported_parent
    assert_not_nil imported_child
    assert_equal "Decision", imported_parent.commentable_type
    assert_equal "Note", imported_child.commentable_type
    # The child should point to the imported parent, not nil
    assert_equal imported_parent.id, imported_child.commentable_id,
      "Child comment should reference imported parent even when child appeared first in JSON"
  end

  test "imports comment on soft-deleted parent note" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    parent_note = create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Will be deleted", text: "Original content",
    )
    # Comment on the note before deleting it
    comment = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Comment on deleted", text: "Still here", subtype: "comment",
      commentable_type: "Note", commentable_id: parent_note.id,
    )
    # Soft-delete the parent
    parent_note.soft_delete!(by: @source_user)

    data_import, imported_collective = export_and_import_source!

    # Both notes should be imported
    all_notes = Note.with_deleted.where(collective_id: imported_collective.id)
    assert all_notes.count >= 2, "Should have at least the deleted parent and the comment"

    imported_parent = all_notes.find_by(title: "[deleted]")
    imported_comment = all_notes.find_by(title: "Comment on deleted")
    assert_not_nil imported_parent, "Soft-deleted parent should be imported"
    assert_not_nil imported_comment, "Comment on deleted parent should be imported"
    assert imported_parent.deleted_at.present?

    # Comment should point to the imported (deleted) parent
    assert_equal "Note", imported_comment.commentable_type
    assert_equal imported_parent.id, imported_comment.commentable_id
  end

  test "imports statements on representation sessions" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    session = RepresentationSession.create!(
      tenant: @source_tenant, collective: @source_collective,
      representative_user_id: @source_user.id,
      began_at: 1.hour.ago, confirmed_understanding: true,
    )
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Session statement", text: "Summary of session", subtype: "statement",
      statementable_type: "RepresentationSession", statementable_id: session.id,
    )

    data_import, imported_collective = export_and_import_source!

    statement = Note.where(collective_id: imported_collective.id, subtype: "statement").first
    assert_not_nil statement
    assert_equal "RepresentationSession", statement.statementable_type
    imported_session = RepresentationSession.where(collective_id: imported_collective.id).first
    assert_equal imported_session.id, statement.statementable_id
  end

  # --- Decision results ---

  test "decision results are correct after import" do
    # Use the existing source decision which already has Option A and a vote from setup
    # Add a second option and more votes to create interesting results
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    option_b = create_option(tenant: @source_tenant, collective: @source_collective, decision: @source_decision, created_by: @source_user, title: "Beta")

    user2 = create_user(name: "Voter Two")
    @source_tenant.add_user!(user2)
    @source_collective.add_user!(user2)

    p2 = DecisionParticipantManager.new(decision: @source_decision, user: user2).find_or_create_participant

    # User 2: accepts Option A, rejects Beta
    Vote.create!(tenant: @source_tenant, collective: @source_collective, decision: @source_decision, option: @source_option, decision_participant: p2, accepted: 1, preferred: 0)
    Vote.create!(tenant: @source_tenant, collective: @source_collective, decision: @source_decision, option: option_b, decision_participant: p2, accepted: 0, preferred: 0)

    # Verify source results exist
    source_results = DecisionResult.where(decision_id: @source_decision.id)
    source_option_a = source_results.find { |r| r.option_title == "Option A" }
    source_beta = source_results.find { |r| r.option_title == "Beta" }
    assert_not_nil source_option_a, "Source should have Option A result"
    assert_not_nil source_beta, "Source should have Beta result"

    data_import, imported_collective = export_and_import_source!

    imported_decision = Decision.where(collective_id: imported_collective.id).first
    imported_results = DecisionResult.where(decision_id: imported_decision.id)

    imported_option_a = imported_results.find { |r| r.option_title == "Option A" }
    imported_beta = imported_results.find { |r| r.option_title == "Beta" }

    assert_not_nil imported_option_a, "Option A result should exist"
    assert_not_nil imported_beta, "Beta result should exist"

    # Option A: 2 accepted (user1 preferred + user2 accepted), 0 rejected, 1 preferred
    assert_equal source_option_a.accepted_yes, imported_option_a.accepted_yes
    assert_equal source_option_a.accepted_no, imported_option_a.accepted_no
    assert_equal source_option_a.preferred, imported_option_a.preferred

    # Beta: 0 accepted, 1 rejected, 0 preferred
    assert_equal source_beta.accepted_yes, imported_beta.accepted_yes
    assert_equal source_beta.accepted_no, imported_beta.accepted_no
    assert_equal source_beta.preferred, imported_beta.preferred
  end

  # --- Reminders ---

  test "imported reminders preserve scheduled time but not notification reference" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    reminder_time = 3.days.from_now.change(usec: 0)
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Future reminder", text: "Don't forget this", subtype: "reminder",
      reminder_scheduled_for: reminder_time, deadline: reminder_time,
    )

    data_import, imported_collective = export_and_import_source!

    imported_reminder = Note.where(collective_id: imported_collective.id, subtype: "reminder").first
    assert_not_nil imported_reminder
    assert_equal "Future reminder", imported_reminder.title
    # reminder_scheduled_for should be preserved for context
    assert imported_reminder.reminder_scheduled_for.present?
    # The notification reference should NOT be set — the source notification doesn't exist in the target
    assert_nil imported_reminder.reminder_notification_id, "Imported reminder should not reference a source notification"
  end

  test "imports decisions with nil description without crashing" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    # Create a decision with nil description (valid per model validation)
    Decision.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "No description?", description: nil, subtype: "vote",
      deadline: 1.week.from_now, options_open: true,
    )

    data_import, imported_collective = export_and_import_source!

    decisions = Decision.where(collective_id: imported_collective.id, question: "No description?")
    assert_equal 1, decisions.count
    assert_nil decisions.first.description
  end

  # --- Edge cases ---

  test "imports empty collective successfully" do
    # Create a fresh empty source collective
    empty_tenant = create_tenant(subdomain: "empty-#{SecureRandom.hex(4)}", name: "Empty Tenant")
    empty_user = create_user(name: "Empty User")
    empty_tenant.add_user!(empty_user)
    Tenant.scope_thread_to_tenant(subdomain: empty_tenant.subdomain)
    empty_collective = create_collective(tenant: empty_tenant, created_by: empty_user, name: "Empty Col", handle: "empty-#{SecureRandom.hex(4)}")
    empty_collective.add_user!(empty_user)
    Collective.scope_thread_to_collective(subdomain: empty_tenant.subdomain, handle: empty_collective.handle)

    export = DataExport.create!(tenant: empty_tenant, collective: empty_collective, user: empty_user, status: "pending")
    CollectiveExportService.new(data_export: export).perform!
    export.reload

    # Import into a different tenant
    target = create_tenant(subdomain: "emptytarget-#{SecureRandom.hex(4)}", name: "Target")
    target.add_user!(empty_user)
    Tenant.scope_thread_to_tenant(subdomain: target.subdomain)
    Collective.clear_thread_scope

    data_import = DataImport.create!(tenant: target, user: empty_user, status: "pending")
    data_import.file.attach(io: StringIO.new(export.file.download), filename: "empty.zip", content_type: "application/zip")
    CollectiveImportService.new(data_import: data_import).perform!

    data_import.reload
    assert_equal "completed", data_import.status
    assert_equal 0, data_import.record_counts.fetch("notes", 0)
    assert_equal 0, data_import.record_counts.fetch("decisions", 0)
  end

  # --- Attachment test ---

  test "exports and imports attachments with binary files" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("hello world attachment content"),
      filename: "test-file.txt",
      content_type: "text/plain",
    )
    Attachment.create!(
      tenant: @source_tenant, collective: @source_collective,
      attachable: @source_note, file: blob,
      created_by: @source_user, updated_by: @source_user,
    )

    # Export
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    export = DataExport.create!(tenant: @source_tenant, collective: @source_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: export).perform!
    export.reload

    # Verify binary file is in the ZIP
    zip_data = T.unsafe(export.file).download
    found_binary = false
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        if entry.name.include?("attachments/") && entry.name.include?("test-file.txt")
          content = io.read
          assert_equal "hello world attachment content", content
          found_binary = true
        end
      end
    end
    assert found_binary, "Binary attachment file not found in export ZIP"

    # Import
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    data_import = DataImport.create!(tenant: @target_tenant, user: @source_user, status: "pending")
    data_import.file.attach(io: StringIO.new(zip_data), filename: "import.zip", content_type: "application/zip")
    CollectiveImportService.new(data_import: data_import).perform!
    data_import.reload

    assert_equal "completed", data_import.status
    assert_equal 1, data_import.record_counts["attachments"]

    # Verify the imported attachment has a file
    imported_collective = Collective.unscoped.find(data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)
    imported_attachments = Attachment.where(collective_id: imported_collective.id)
    assert_equal 1, imported_attachments.count
    assert imported_attachments.first.file.attached?, "Imported attachment should have a file"
  end

  # --- Edge cases ---

  test "second import of same export gets suffixed handle" do
    # First import
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!
    @data_import.reload
    first_collective = Collective.unscoped.find(@data_import.collective_id)

    # Second import of same export
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    import2 = DataImport.create!(tenant: @target_tenant, user: @source_user, status: "pending")
    import2.file.attach(io: StringIO.new(@export.file.download), filename: "import2.zip", content_type: "application/zip")
    CollectiveImportService.new(data_import: import2).perform!
    import2.reload

    second_collective = Collective.unscoped.find(import2.collective_id)
    assert_not_equal first_collective.id, second_collective.id
    assert_not_equal first_collective.handle, second_collective.handle
    assert second_collective.handle.include?("imported"), "Second import should have suffixed handle: #{second_collective.handle}"
  end

  test "handles collective handle collision by appending suffix" do
    # Create a collective in the target tenant with the same handle
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    existing = create_collective(tenant: @target_tenant, created_by: @source_user, name: "Existing", handle: @source_collective.handle)

    Collective.clear_thread_scope
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.unscoped.find(@data_import.collective_id)
    assert_not_equal existing.id, imported_collective.id
    assert imported_collective.handle.start_with?(@source_collective.handle), "Handle should start with original"
    assert imported_collective.handle.include?("imported"), "Handle should include 'imported' suffix"
  end

  # --- Round-trip test ---

  test "round-trip: export -> import -> re-export produces equivalent data" do
    # Step 1: Import the exported data
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)

    # Step 2: Re-export the imported collective
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    re_export = DataExport.create!(
      tenant: @target_tenant,
      collective: imported_collective,
      user: @source_user,
      status: "pending",
    )
    CollectiveExportService.new(data_export: re_export).perform!
    re_export.reload

    # Step 3: Compare the two exports (ignoring IDs, timestamps that change)
    original_zip = extract_all_json(@export)
    reimported_zip = extract_all_json(re_export)

    # Collective name and handle should match
    assert_equal original_zip["collective.json"]["name"], reimported_zip["collective.json"]["name"]
    assert_equal original_zip["collective.json"]["handle"], reimported_zip["collective.json"]["handle"]

    # Same number of notes
    assert_equal original_zip["notes.json"].length, reimported_zip["notes.json"].length
    # Same note titles
    original_titles = original_zip["notes.json"].map { |n| n["title"] }.sort
    reimported_titles = reimported_zip["notes.json"].map { |n| n["title"] }.sort
    assert_equal original_titles, reimported_titles

    # Same number of decisions
    assert_equal original_zip["decisions.json"].length, reimported_zip["decisions.json"].length
    # Same questions
    original_questions = original_zip["decisions.json"].map { |d| d["question"] }.sort
    reimported_questions = reimported_zip["decisions.json"].map { |d| d["question"] }.sort
    assert_equal original_questions, reimported_questions

    # Same number of options
    assert_equal original_zip["options.json"].length, reimported_zip["options.json"].length

    # Same number of votes with same values
    assert_equal original_zip["votes.json"].length, reimported_zip["votes.json"].length
    original_votes = original_zip["votes.json"].map { |v| [v["accepted"], v["preferred"]] }.sort
    reimported_votes = reimported_zip["votes.json"].map { |v| [v["accepted"], v["preferred"]] }.sort
    assert_equal original_votes, reimported_votes

    # Same number of commitments
    assert_equal original_zip["commitments.json"].length, reimported_zip["commitments.json"].length

    # Same number of commitment participants
    assert_equal original_zip["commitment_participants.json"].length, reimported_zip["commitment_participants.json"].length

    # Same number of decision audit entries
    assert_equal original_zip["decision_audit_entries.json"].length, reimported_zip["decision_audit_entries.json"].length

    # Same number of note history events
    assert_equal original_zip["note_history_events.json"].length, reimported_zip["note_history_events.json"].length

    # Same number of heartbeats
    assert_equal original_zip["heartbeats.json"]&.length || 0, reimported_zip["heartbeats.json"]&.length || 0

    # Same number of members
    assert_equal original_zip["members.json"].length, reimported_zip["members.json"].length

    # Record counts match
    assert_equal original_zip["manifest.json"]["record_counts"]["notes"], reimported_zip["manifest.json"]["record_counts"]["notes"]
    assert_equal original_zip["manifest.json"]["record_counts"]["decisions"], reimported_zip["manifest.json"]["record_counts"]["decisions"]
  end

  test "round-trip preserves comments and statements with correct structure" do
    # Enrich the source with comments and statements
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    comment_on_decision = Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Decision comment", text: "Thoughts", subtype: "comment",
      commentable_type: "Decision", commentable_id: @source_decision.id,
    )
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Nested reply", text: "Agree", subtype: "comment",
      commentable_type: "Note", commentable_id: comment_on_decision.id,
    )
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Decision statement", text: "Final word", subtype: "statement",
      statementable_type: "Decision", statementable_id: @source_decision.id,
    )
    Note.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Commitment comment", text: "On track", subtype: "comment",
      commentable_type: "Commitment", commentable_id: @source_commitment.id,
    )

    # Export source
    export = DataExport.create!(tenant: @source_tenant, collective: @source_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: export).perform!
    export.reload

    # Import into target
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    data_import = DataImport.create!(tenant: @target_tenant, user: @source_user, status: "pending")
    data_import.file.attach(io: StringIO.new(export.file.download), filename: "import.zip", content_type: "application/zip")
    CollectiveImportService.new(data_import: data_import).perform!
    data_import.reload
    imported_collective = Collective.unscoped.find(data_import.collective_id)

    # Re-export
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)
    re_export = DataExport.create!(tenant: @target_tenant, collective: imported_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: re_export).perform!
    re_export.reload

    original = extract_all_json(export)
    reimported = extract_all_json(re_export)

    # Same total note count (text notes + comments + statements)
    assert_equal original["notes.json"].length, reimported["notes.json"].length

    # Same subtypes
    original_subtypes = original["notes.json"].map { |n| n["subtype"] }.sort
    reimported_subtypes = reimported["notes.json"].map { |n| n["subtype"] }.sort
    assert_equal original_subtypes, reimported_subtypes

    # Same comment structure: each comment's commentable_type is preserved
    original_comments = original["notes.json"].select { |n| n["subtype"] == "comment" }
    reimported_comments = reimported["notes.json"].select { |n| n["subtype"] == "comment" }
    assert_equal original_comments.length, reimported_comments.length

    # Verify nested reply still points to a Note (not a Decision)
    original_nested = original_comments.find { |n| n["title"] == "Nested reply" }
    reimported_nested = reimported_comments.find { |n| n["title"] == "Nested reply" }
    assert_equal "Note", original_nested["source_commentable_type"]
    assert_equal "Note", reimported_nested["source_commentable_type"]

    # Verify statement exists in re-export
    original_statements = original["notes.json"].select { |n| n["subtype"] == "statement" }
    reimported_statements = reimported["notes.json"].select { |n| n["subtype"] == "statement" }
    assert_equal original_statements.length, reimported_statements.length
  end

  private

  def read_json_from_zip(filename)
    assert @data_import.file.attached?, "No file attached"
    zip_data = T.unsafe(@data_import.file).download
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        if entry.name.end_with?("/#{filename}") || entry.name == filename
          return JSON.parse(io.read)
        end
      end
    end
    raise "#{filename} not found in ZIP"
  end

  def extract_all_json(data_export)
    result = {}
    zip_data = T.unsafe(data_export.file).download
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        next if entry.directory?
        name = entry.name.sub(%r{^[^/]+/}, "")
        next unless name.end_with?(".json")
        result[name] = JSON.parse(io.read)
      end
    end
    result
  end

  # Helper: export the source collective and import into the target tenant.
  # Yields the imported collective (with scope set) so tests can assert against it.
  def export_and_import_source!
    # Export
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    export = DataExport.create!(tenant: @source_tenant, collective: @source_collective, user: @source_user, status: "pending")
    CollectiveExportService.new(data_export: export).perform!
    export.reload

    # Import
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    data_import = DataImport.create!(tenant: @target_tenant, user: @source_user, status: "pending")
    data_import.file.attach(io: StringIO.new(export.file.download), filename: "import.zip", content_type: "application/zip")
    CollectiveImportService.new(data_import: data_import).perform!
    data_import.reload

    imported_collective = Collective.unscoped.find(data_import.collective_id)
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)

    [data_import, imported_collective]
  end
end
