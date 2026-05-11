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

    # Target: different tenant. The @source_user User row is reused because the
    # User table is shared across tenants (User is not tenant-scoped); the import
    # adds the user to the target tenant as part of import_members.
    @target_tenant = create_tenant(subdomain: "target-#{SecureRandom.hex(4)}", name: "Target Tenant")

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

  test "matches existing users by UUID (same-instance import)" do
    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)

    # The source_user should be a member of the imported collective (matched by UUID
    # — User table is shared across tenants so the source ID resolves directly).
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)
    members = CollectiveMember.where(collective_id: imported_collective.id)
    member_user_ids = members.pluck(:user_id)
    assert_includes member_user_ids, @source_user.id

    # user_mapping is keyed by source handle, with name + matched status
    mapping = @data_import.user_mapping
    source_handle = @source_tenant.tenant_users.find_by(user_id: @source_user.id).handle
    matched_entry = mapping[source_handle]
    assert matched_entry.present?
    assert_equal true, matched_entry["matched"]
    assert_equal @source_user.id, matched_entry["target_user_id"]
  end

  test "matches users by handle→email map when UUID match fails (cross-instance)" do
    # Create a target user with a known email; the map will resolve to them.
    other_email = "other-#{SecureRandom.hex(6)}@example.com"
    other_user = create_user(email: other_email, name: "Other User")
    @target_tenant.add_user!(other_user)

    # Build a synthetic export ZIP with a fake source_id (no User in our DB
    # has this UUID) so UUID matching fails. The handle is what the admin
    # supplies in the map.
    fake_source_id = SecureRandom.uuid
    source_handle = "imported-user"
    zip_path = build_synthetic_export_zip(
      user_source_id: fake_source_id,
      user_handle: source_handle,
      user_name: "Imported User",
    )

    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    data_import = DataImport.create!(
      tenant: @target_tenant,
      user: @source_user,
      status: "pending",
      import_options: { "handle_email_map" => { source_handle => other_email } },
    )
    data_import.file.attach(io: File.open(zip_path), filename: "synthetic.zip", content_type: "application/zip")

    CollectiveImportService.new(data_import: data_import).perform!

    data_import.reload
    assert_equal "completed", data_import.status

    # other_user (matched via the map) is now a member of the imported collective
    imported_collective = Collective.find(data_import.collective_id)
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)
    member_user_ids = CollectiveMember.where(collective_id: imported_collective.id).pluck(:user_id)
    assert_includes member_user_ids, other_user.id, "Map-matched user should be a member of imported collective"

    # user_mapping reflects the match (not a placeholder)
    mapping = data_import.user_mapping[source_handle]
    assert_equal true, mapping["matched"]
    assert_equal other_user.id, mapping["target_user_id"]

    # No imported_placeholder was created for that handle
    refute User.where(name: "Imported User", user_type: "imported_placeholder").exists?
  end

  test "falls back to placeholder when handle is in map but email doesn't match any user" do
    fake_source_id = SecureRandom.uuid
    source_handle = "imported-user"
    zip_path = build_synthetic_export_zip(
      user_source_id: fake_source_id,
      user_handle: source_handle,
      user_name: "Imported User",
    )

    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    Collective.clear_thread_scope
    data_import = DataImport.create!(
      tenant: @target_tenant,
      user: @source_user,
      status: "pending",
      import_options: { "handle_email_map" => { source_handle => "no-such-user@example.com" } },
    )
    data_import.file.attach(io: File.open(zip_path), filename: "synthetic.zip", content_type: "application/zip")

    CollectiveImportService.new(data_import: data_import).perform!

    data_import.reload
    assert_equal "completed", data_import.status

    # No real user matched → placeholder created
    mapping = data_import.user_mapping[source_handle]
    assert_equal false, mapping["matched"]
    assert mapping["placeholder"]
    placeholder = User.find(mapping["target_user_id"])
    assert_equal "imported_placeholder", placeholder.user_type
  end

  test "import_members survives handle collisions in target tenant" do
    # Pre-populate target tenant with a TenantUser whose handle parameterizes
    # the same way as @source_user's name. This used to crash the import with
    # PG::UniqueViolation because Tenant#add_user! tries to create a TenantUser
    # with handle = name.parameterize.
    colliding_user = create_user(email: "colliding-#{SecureRandom.hex(4)}@example.com", name: "Source User")
    @target_tenant.add_user!(colliding_user)
    refute_nil TenantUser.find_by(tenant_id: @target_tenant.id, handle: "source-user")

    @data_import.update!(import_options: { "use_placeholders" => true })

    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    assert_equal "completed", @data_import.status

    # The placeholder ended up with a suffixed handle
    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: Collective.find(@data_import.collective_id).handle)
    placeholder_handles = TenantUser.where(tenant_id: @target_tenant.id).pluck(:handle)
    assert_includes placeholder_handles, "source-user-imported-1"
  end

  test "importing admin is added as admin member of the imported collective" do
    # Repros: with use_placeholders=true, every source member becomes a
    # placeholder, so the real importing admin can't access the imported
    # collective at all (no real user is a member, and only existing members
    # can invite). Even without placeholders, if the importing admin wasn't
    # a member of the source collective, they'd have no way in.
    @data_import.update!(import_options: { "use_placeholders" => true })

    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)

    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)
    member = CollectiveMember.find_by(collective_id: imported_collective.id, user_id: @data_import.user_id)
    assert_not_nil member, "Importing admin must be a member of the imported collective"
    assert member.is_admin?, "Importing admin must have admin role on the imported collective"
    assert_nil member.archived_at, "Importing admin's membership must not be archived"
  end

  test "marks import as failed cleanly when an import step raises after import_collective" do
    # Reproduces the bug where the rescue's update! would itself fail with a
    # foreign-key violation because the rolled-back collective_id was still
    # dirty in memory. Now we use update_columns to bypass that.
    service = CollectiveImportService.new(data_import: @data_import)
    service.define_singleton_method(:import_members) { raise StandardError, "synthetic failure" }

    assert_raises(StandardError) do
      service.perform!
    end

    @data_import.reload
    assert_equal "failed", @data_import.status
    assert_equal "synthetic failure", @data_import.error_message
  end

  test "creates placeholder users when use_placeholders flag is set" do
    @data_import.update!(import_options: { "use_placeholders" => true })

    service = CollectiveImportService.new(data_import: @data_import)
    service.perform!

    @data_import.reload
    imported_collective = Collective.find(@data_import.collective_id)

    Collective.scope_thread_to_collective(subdomain: @target_tenant.subdomain, handle: imported_collective.handle)
    members = CollectiveMember.where(collective_id: imported_collective.id)
    member_user_ids = members.pluck(:user_id)

    # The importer is added as a real member regardless of the placeholder flag,
    # so they retain access to the imported collective.
    assert_includes member_user_ids, @data_import.user_id, "Importer should be a member"

    # All OTHER members (the source's own membership records) should be placeholders.
    other_member_ids = member_user_ids - [@data_import.user_id]
    refute_empty other_member_ids
    placeholder_users = User.where(id: other_member_ids, user_type: "imported_placeholder")
    assert_equal other_member_ids.sort, placeholder_users.pluck(:id).sort,
                 "Non-importer members should all be placeholders"

    # Placeholders use synthetic @imported.invalid emails
    placeholder_emails = placeholder_users.pluck(:email)
    assert placeholder_emails.all? { |e| e.end_with?("@imported.invalid") },
           "Expected synthetic emails, got: #{placeholder_emails}"
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

    comments = Note.where(collective_id: imported_collective.id, subtype: "comment")
    assert_equal 2, comments.count

    parent = comments.find_by!(title: "Parent comment")
    reply = comments.find_by!(title: "Reply")
    assert_equal "Decision", parent.commentable_type
    assert_equal "Note", reply.commentable_type
    # Reply's commentable_id should point to the imported parent comment
    assert_equal parent.id, reply.commentable_id
  end

  # --- Decision audit entry round-trip ---

  test "imports decision audit entries: preserves schema_version + actor_token, drops salt, marks as :imported" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    # Create a fresh decision + audit chain on the source side so we control the entries.
    decision = Decision.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "Round-trip audit?", deadline: 1.week.from_now, options_open: true, subtype: "vote",
    )
    DecisionAuditService.record_creation!(decision: decision, actor: @source_user)
    option = create_option(decision: decision, created_by: @source_user, title: "Option A")
    DecisionAuditService.record_option!(
      decision: decision, option: option, actor: @source_user, action: "option_added",
    )

    source_entries = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).to_a
    assert_equal 2, source_entries.size, "precondition: source has 2 audit entries"
    actor_entry = source_entries.find { |e| e.actor_id.present? }
    source_token = actor_entry.actor_token
    assert_equal 2, actor_entry.schema_version
    assert_match(/\A[0-9a-f]{64}\z/, source_token)
    assert_match(/\A[0-9a-f]{64}\z/, actor_entry.actor_token_salt)

    _data_import, imported_collective = export_and_import_source!

    imported_decision = Decision.where(collective_id: imported_collective.id, question: "Round-trip audit?").first
    imported_entries = DecisionAuditEntry.where(decision_id: imported_decision.id).order(:sequence_number).to_a
    assert_equal source_entries.size, imported_entries.size

    imported_actor_entry = imported_entries.find { |e| e.action == "option_added" }
    assert_equal 2, imported_actor_entry.schema_version, "schema_version must be preserved"
    assert_equal source_token, imported_actor_entry.actor_token,
                 "actor_token must be preserved verbatim for forensic traceability"
    assert_nil imported_actor_entry.actor_token_salt,
               "actor_token_salt must be NULLed on import (it was the source secret; carrying it across is misleading)"
    assert_equal true, imported_actor_entry.metadata["imported"],
                 "metadata.imported flag is what distinguishes :imported from :unattributable"

    # Binding check on the imported entry returns :imported, not :tamper_or_scrub_inconsistent
    # — the chain stays valid in the target instance.
    assert_equal :imported, DecisionAuditVerifier.verify_actor_binding(imported_actor_entry)
  end

  test "imports decision audit entries: verify_all reports expected statuses end-to-end" do
    # End-to-end: build a multi-entry chain on the source (actor entries + a
    # system entry), round-trip it through export/import, then run the full
    # verifier on the imported decision. Pins what consumers of the verify
    # endpoint will actually see for an imported chain.
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    decision = Decision.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "End-to-end verify?", deadline: 1.week.from_now, options_open: true, subtype: "vote",
    )
    DecisionAuditService.record_creation!(decision: decision, actor: @source_user)
    option = create_option(decision: decision, created_by: @source_user, title: "Option A")
    DecisionAuditService.record_option!(
      decision: decision, option: option, actor: @source_user, action: "option_added",
    )
    # System entry (no actor) — exercises :no_actor in binding_statuses
    DecisionAuditService.record_beacon!(decision: decision, round: 99, randomness: "deadbeef")

    _data_import, imported_collective = export_and_import_source!

    imported_decision = Decision.where(collective_id: imported_collective.id, question: "End-to-end verify?").first
    result = DecisionAuditVerifier.verify_all(imported_decision)

    # Chain integrity fails on imported chains by design: the import adds
    # metadata.imported to every entry, which changes the recomputed hash.
    # The verify view explains this to users via the imported banner.
    refute result[:chain][:valid], "imported chain hash mismatch is expected, not a bug"
    assert result[:chain][:errors].any? { |e| e.include?("hash mismatch") }

    # Binding accounting: every actor entry imports as :imported (not
    # :tamper_or_scrub_inconsistent), and binding_inconsistent_count stays 0.
    assert_equal 2, result[:chain][:imported_count]
    assert_equal 0, result[:chain][:scrubbed_count]
    assert_equal 0, result[:chain][:binding_inconsistent_count]

    statuses = result[:chain][:binding_statuses]
    assert_equal 3, statuses.size
    assert_equal :imported, statuses[1], "decision_created → :imported"
    assert_equal :imported, statuses[2], "option_added → :imported"
    assert_equal :no_actor, statuses[3], "beacon_drawn has no actor → :no_actor"
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

    comments = Note.where(collective_id: imported_collective.id, subtype: "comment")
    assert_equal 3, comments.count

    imported_l1 = comments.find_by!(title: "Level 1")
    imported_l2 = comments.find_by!(title: "Level 2")
    imported_l3 = comments.find_by!(title: "Level 3")

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

  # --- Deadline event preservation ---

  test "preserves deadline_event_fired_at on imported decisions" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    fired_time = 2.days.ago.change(usec: 0)
    @source_decision.update_columns(deadline_event_fired_at: fired_time)

    data_import, imported_collective = export_and_import_source!

    imported_decision = Decision.where(collective_id: imported_collective.id).first
    assert imported_decision.deadline_event_fired_at.present?,
      "deadline_event_fired_at should be preserved to prevent duplicate deadline events"
    assert_in_delta fired_time.to_f, imported_decision.deadline_event_fired_at.to_f, 1.0
  end

  test "preserves deadline_event_fired_at on imported commitments" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    fired_time = 1.day.ago.change(usec: 0)
    @source_commitment.update_columns(deadline_event_fired_at: fired_time)

    data_import, imported_collective = export_and_import_source!

    imported_commitment = Commitment.where(collective_id: imported_collective.id).first
    assert imported_commitment.deadline_event_fired_at.present?,
      "deadline_event_fired_at should be preserved to prevent duplicate deadline events"
    assert_in_delta fired_time.to_f, imported_commitment.deadline_event_fired_at.to_f, 1.0
  end

  # --- Text rewriting ---

  test "rewrites markdown path links in note text after import" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    # Create a note that links to the source decision using a markdown path link
    source_decision_path = "/collectives/#{@source_collective.handle}/d/#{@source_decision.truncated_id}"
    create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Linking note", text: "See [the decision](#{source_decision_path}) for details.",
    )

    data_import, imported_collective = export_and_import_source!

    imported_note = Note.where(collective_id: imported_collective.id, title: "Linking note").first
    imported_decision = Decision.where(collective_id: imported_collective.id).first

    # The text should now reference the imported decision's truncated_id and new collective handle
    assert_includes imported_note.text, imported_decision.truncated_id,
      "Text should contain the new truncated_id, not the source one"
    assert_includes imported_note.text, imported_collective.handle,
      "Text should contain the new collective handle"
    assert_not_includes imported_note.text, @source_decision.truncated_id,
      "Text should NOT contain the source truncated_id"
  end

  test "rewrites full URLs in note text after import" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    hostname = ENV.fetch("HOSTNAME", "localhost")
    full_url = "https://#{@source_tenant.subdomain}.#{hostname}/collectives/#{@source_collective.handle}/d/#{@source_decision.truncated_id}"
    create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Full URL note", text: "Check out #{full_url} for the vote.",
    )

    data_import, imported_collective = export_and_import_source!

    imported_note = Note.where(collective_id: imported_collective.id, title: "Full URL note").first
    imported_decision = Decision.where(collective_id: imported_collective.id).first

    assert_includes imported_note.text, imported_decision.truncated_id
    assert_not_includes imported_note.text, @source_decision.truncated_id
  end

  test "rewrites @ mentions in note text after import" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    # Give the source user a distinct handle so we can prove rewriting happened
    source_tenant_user = TenantUser.find_by(tenant_id: @source_tenant.id, user_id: @source_user.id)
    source_tenant_user.update!(handle: "source-handle-#{SecureRandom.hex(4)}")
    source_handle = source_tenant_user.handle

    create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Mention note", text: "Hey @#{source_handle}, what do you think?",
    )

    data_import, imported_collective = export_and_import_source!

    imported_note = Note.where(collective_id: imported_collective.id, title: "Mention note").first
    target_tenant_user = TenantUser.find_by(tenant_id: @target_tenant.id, user_id: @source_user.id)
    target_handle = target_tenant_user.handle

    # Handles should differ (source was customized, target uses default)
    assert_not_equal source_handle, target_handle, "Handles should differ for this test to be meaningful"
    assert_includes imported_note.text, "@#{target_handle}",
      "Text should contain the target tenant handle"
    assert_not_includes imported_note.text, "@#{source_handle}",
      "Text should NOT contain the source handle"
  end

  test "rewrites links in decision descriptions after import" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_note_path = "/collectives/#{@source_collective.handle}/n/#{@source_note.truncated_id}"
    decision = Decision.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "Linking decision", description: "Related to [this note](#{source_note_path}).",
      deadline: 1.week.from_now, options_open: true,
    )

    data_import, imported_collective = export_and_import_source!

    imported_decision = Decision.where(collective_id: imported_collective.id, question: "Linking decision").first
    imported_note = Note.where(collective_id: imported_collective.id, title: "Import Test Note").first

    assert_includes imported_decision.description, imported_note.truncated_id,
      "Decision description should reference the new note truncated_id"
    assert_not_includes imported_decision.description, @source_note.truncated_id,
      "Decision description should NOT contain the source truncated_id"
  end

  test "rewrites links in commitment descriptions after import" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_note_path = "/collectives/#{@source_collective.handle}/n/#{@source_note.truncated_id}"
    Commitment.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Linking commitment", description: "See [notes](#{source_note_path}) for context.",
      critical_mass: 1, deadline: 1.week.from_now,
    )

    data_import, imported_collective = export_and_import_source!

    imported_commitment = Commitment.where(collective_id: imported_collective.id, title: "Linking commitment").first
    imported_note = Note.where(collective_id: imported_collective.id, title: "Import Test Note").first

    assert_includes imported_commitment.description, imported_note.truncated_id
    assert_not_includes imported_commitment.description, @source_note.truncated_id
  end

  test "rewrites mixed links and mentions in the same text" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_tenant_user = TenantUser.find_by(tenant_id: @source_tenant.id, user_id: @source_user.id)
    source_tenant_user.update!(handle: "mixed-source-#{SecureRandom.hex(4)}")
    source_handle = source_tenant_user.handle

    source_decision_path = "/collectives/#{@source_collective.handle}/d/#{@source_decision.truncated_id}"
    source_note_path = "/collectives/#{@source_collective.handle}/n/#{@source_note.truncated_id}"
    mixed_text = "Hey @#{source_handle}, check [decision](#{source_decision_path}) and [note](#{source_note_path})."

    create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Mixed content", text: mixed_text,
    )

    data_import, imported_collective = export_and_import_source!

    imported = Note.where(collective_id: imported_collective.id, title: "Mixed content").first
    imported_decision = Decision.where(collective_id: imported_collective.id).first
    imported_note = Note.where(collective_id: imported_collective.id, title: "Import Test Note").first
    target_handle = TenantUser.find_by(tenant_id: @target_tenant.id, user_id: @source_user.id).handle

    # All three references should be rewritten
    assert_includes imported.text, imported_decision.truncated_id
    assert_includes imported.text, imported_note.truncated_id
    assert_includes imported.text, "@#{target_handle}"
    # None of the source references should remain
    assert_not_includes imported.text, @source_decision.truncated_id
    assert_not_includes imported.text, @source_note.truncated_id
    assert_not_includes imported.text, "@#{source_handle}"
  end

  test "creates Link records from rewritten text" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_decision_path = "/collectives/#{@source_collective.handle}/d/#{@source_decision.truncated_id}"
    create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Link source", text: "References [decision](#{source_decision_path}).",
    )

    data_import, imported_collective = export_and_import_source!

    imported_note = Note.where(collective_id: imported_collective.id, title: "Link source").first
    imported_decision = Decision.where(collective_id: imported_collective.id).first

    # Link records should have been created from the rewritten text
    links = Link.where(collective_id: imported_collective.id)
    assert links.any?, "Link records should exist after import with text rewriting"
    link = links.find { |l| l.from_linkable_id == imported_note.id && l.to_linkable_id == imported_decision.id }
    assert_not_nil link, "Should have a Link from the imported note to the imported decision"
  end

  test "rewrites mentions in decision question field" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_tu = TenantUser.find_by(tenant_id: @source_tenant.id, user_id: @source_user.id)
    source_tu.update!(handle: "question-source-#{SecureRandom.hex(4)}")

    Decision.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      question: "Should @#{source_tu.handle} lead?", description: "Details here",
      deadline: 1.week.from_now, options_open: true,
    )

    data_import, imported_collective = export_and_import_source!

    imported = Decision.where(collective_id: imported_collective.id).find_by("question LIKE '%lead?'")
    target_handle = TenantUser.find_by(tenant_id: @target_tenant.id, user_id: @source_user.id).handle

    assert_not_equal source_tu.handle, target_handle
    assert_includes imported.question, "@#{target_handle}"
    assert_not_includes imported.question, "@#{source_tu.handle}"
  end

  test "rewrites mentions in commitment title field" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_tu = TenantUser.find_by(tenant_id: @source_tenant.id, user_id: @source_user.id)
    source_tu.update!(handle: "title-source-#{SecureRandom.hex(4)}")

    Commitment.create!(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "@#{source_tu.handle}'s pledge", description: "Do the thing",
      critical_mass: 1, deadline: 1.week.from_now,
    )

    data_import, imported_collective = export_and_import_source!

    imported = Commitment.where(collective_id: imported_collective.id).find_by("title LIKE '%pledge'")
    target_handle = TenantUser.find_by(tenant_id: @target_tenant.id, user_id: @source_user.id).handle

    assert_not_equal source_tu.handle, target_handle
    assert_includes imported.title, "@#{target_handle}"
    assert_not_includes imported.title, "@#{source_tu.handle}"
  end

  test "rewrites mentions in option title and description" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_tu = TenantUser.find_by(tenant_id: @source_tenant.id, user_id: @source_user.id)
    source_tu.update!(handle: "opt-source-#{SecureRandom.hex(4)}")

    option = Option.find(@source_option.id)
    option.update_columns(
      title: "@#{source_tu.handle}'s proposal",
      description: "Proposed by @#{source_tu.handle}",
    )

    data_import, imported_collective = export_and_import_source!

    imported_decision = Decision.where(collective_id: imported_collective.id).first
    imported_option = Option.where(decision_id: imported_decision.id).first
    target_handle = TenantUser.find_by(tenant_id: @target_tenant.id, user_id: @source_user.id).handle

    assert_not_equal source_tu.handle, target_handle
    assert_includes imported_option.title, "@#{target_handle}"
    assert_not_includes imported_option.title, "@#{source_tu.handle}"
    assert_includes imported_option.description, "@#{target_handle}"
  end

  test "rewrites links in note title field" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    source_tu = TenantUser.find_by(tenant_id: @source_tenant.id, user_id: @source_user.id)
    source_tu.update!(handle: "title-note-source-#{SecureRandom.hex(4)}")

    create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Note by @#{source_tu.handle}", text: "Body content",
    )

    data_import, imported_collective = export_and_import_source!

    target_handle = TenantUser.find_by(tenant_id: @target_tenant.id, user_id: @source_user.id).handle
    imported_note = Note.where(collective_id: imported_collective.id).find_by("title LIKE '%Note by%'")

    assert_not_equal source_tu.handle, target_handle
    assert_includes imported_note.title, "@#{target_handle}"
    assert_not_includes imported_note.title, "@#{source_tu.handle}"
  end

  test "rewrites pasted attachment URLs including attachment UUID after import" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    # Create a real attachment on the source note
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("attachment content"), filename: "screenshot.txt", content_type: "text/plain",
    )
    attachment = Attachment.create!(
      tenant: @source_tenant, collective: @source_collective,
      attachable: @source_note, file: blob,
      created_by: @source_user, updated_by: @source_user,
    )

    # Paste the attachment URL into another note's text
    pasted_url = "/collectives/#{@source_collective.handle}/n/#{@source_note.truncated_id}/attachments/#{attachment.id}"
    create_note(
      tenant: @source_tenant, collective: @source_collective, created_by: @source_user,
      title: "Attachment URL note", text: "See ![screenshot](#{pasted_url}) for reference.",
    )

    data_import, imported_collective = export_and_import_source!

    imported_note = Note.where(collective_id: imported_collective.id, title: "Attachment URL note").first
    imported_target_note = Note.where(collective_id: imported_collective.id, title: "Import Test Note").first
    imported_attachment = Attachment.where(collective_id: imported_collective.id).first

    # The note truncated_id, collective handle, AND attachment UUID should all be rewritten
    assert_includes imported_note.text, imported_target_note.truncated_id,
      "Pasted attachment URL should have the new note truncated_id"
    assert_includes imported_note.text, imported_collective.handle,
      "Pasted attachment URL should have the new collective handle"
    assert_includes imported_note.text, imported_attachment.id,
      "Pasted attachment URL should have the new attachment UUID"
    assert_not_includes imported_note.text, attachment.id,
      "Pasted attachment URL should NOT have the source attachment UUID"
  end

  # --- Side effect suppression ---

  test "does not create Event records during import" do
    data_import, imported_collective = export_and_import_source!

    # Events are created by the Tracked concern on after_create_commit.
    # Import should suppress these — imported data should not generate new Events.
    events = Event.where(collective_id: imported_collective.id)
    assert_equal 0, events.count,
      "Import should not create Event records (got #{events.count}: #{events.pluck(:event_type).join(', ')})"
  end

  test "does not create UserItemStatus records during import" do
    data_import, imported_collective = export_and_import_source!

    # UserItemStatus tracks who created/read/voted on items. Import should not
    # create these records — they reflect activity in the source, not the target.
    imported_note_ids = Note.where(collective_id: imported_collective.id).pluck(:id)
    imported_decision_ids = Decision.where(collective_id: imported_collective.id).pluck(:id)
    all_item_ids = imported_note_ids + imported_decision_ids

    statuses = UserItemStatus.where(item_id: all_item_ids)
    assert_equal 0, statuses.count,
      "Import should not create UserItemStatus records"
  end

  test "imports votes on past-deadline decisions without trigger rejection" do
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)

    # Simulate a decision whose deadline has passed: the vote was cast before the
    # deadline, then the deadline expired. Set timestamps to reflect this history.
    @source_decision.update_columns(deadline: 2.days.ago)
    @source_vote.update_columns(created_at: 3.days.ago, updated_at: 3.days.ago)

    # The source already has a vote from setup — export it
    data_import, imported_collective = export_and_import_source!

    # The vote should have been imported despite the past deadline
    imported_decision = Decision.where(collective_id: imported_collective.id).first
    votes = Vote.where(decision_id: imported_decision.id)
    assert_equal 1, votes.count, "Vote should be imported even though deadline has passed"
  end

  # --- Tenant user access control ---

  test "does not escalate access for archived tenant users" do
    # Create a second user in the source collective
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    revoked_user = create_user(name: "Revoked User")
    @source_tenant.add_user!(revoked_user)
    @source_collective.add_user!(revoked_user)
    create_note(tenant: @source_tenant, collective: @source_collective, created_by: revoked_user, title: "Revoked user note")

    # In the target tenant, this user exists but has been archived (access revoked)
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    @target_tenant.add_user!(revoked_user)
    target_tu = TenantUser.find_by(tenant_id: @target_tenant.id, user_id: revoked_user.id)
    target_tu.update!(archived_at: 1.day.ago)

    data_import, imported_collective = export_and_import_source!

    # The archived tenant user should NOT be unarchived
    target_tu.reload
    assert target_tu.archived?, "Archived TenantUser should remain archived after import"

    # The user should be a member of the imported collective, but archived
    member = CollectiveMember.find_by(collective_id: imported_collective.id, user_id: revoked_user.id)
    assert_not_nil member, "User should still be added as a collective member (for data integrity)"
    assert member.archived?, "Collective member should be archived since their tenant access is revoked"
  end

  test "active tenant users get active collective membership on import" do
    # Create a second user in the source collective
    Tenant.scope_thread_to_tenant(subdomain: @source_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @source_tenant.subdomain, handle: @source_collective.handle)
    active_user = create_user(name: "Active User")
    @source_tenant.add_user!(active_user)
    @source_collective.add_user!(active_user)

    # In the target tenant, this user exists and is active
    Tenant.scope_thread_to_tenant(subdomain: @target_tenant.subdomain)
    @target_tenant.add_user!(active_user)

    data_import, imported_collective = export_and_import_source!

    # Active tenant user should get active collective membership
    member = CollectiveMember.find_by(collective_id: imported_collective.id, user_id: active_user.id)
    assert_not_nil member
    assert_not member.archived?, "Active tenant user should get active collective membership"
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

    # Same number of links
    assert_equal original_zip["links.json"].length, reimported_zip["links.json"].length

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

  # Builds a minimal-but-valid export ZIP with a single user record whose
  # source_id is a brand-new UUID (so UUID matching on import will fail).
  # Lets us exercise the cross-instance code paths (map matching, placeholder
  # fallback) without a real source instance.
  def build_synthetic_export_zip(user_source_id:, user_handle:, user_name:)
    require "zip"
    path = Rails.root.join("tmp", "synthetic-export-#{SecureRandom.hex(4)}.zip")
    @synthetic_zip_paths ||= []
    @synthetic_zip_paths << path.to_s

    collective_handle = "synth-#{SecureRandom.hex(4)}"
    Zip::OutputStream.open(path.to_s) do |zos|
      zos.put_next_entry("export/manifest.json")
      zos.write(JSON.generate({
        "format_version" => "1.0",
        "app_version" => "1.0.0",
        "exported_at" => Time.current.iso8601,
        "source_instance" => "synthetic.test",
        "source_subdomain" => "synthetic",
        "collective" => { "name" => "Synthetic", "handle" => collective_handle },
        "record_counts" => {},
        "checksums" => {},
      }))

      zos.put_next_entry("export/collective.json")
      zos.write(JSON.generate({
        "source_id" => SecureRandom.uuid,
        "name" => "Synthetic",
        "handle" => collective_handle,
        "collective_type" => "standard",
        "settings" => {},
        "source_created_by_id" => user_source_id,
        "created_at" => Time.current.iso8601,
        "updated_at" => Time.current.iso8601,
      }))

      zos.put_next_entry("export/users.json")
      zos.write(JSON.generate([{
        "source_id" => user_source_id,
        "name" => user_name,
        "user_type" => "human",
        "handle" => user_handle,
      }]))

      zos.put_next_entry("export/members.json")
      zos.write(JSON.generate([{
        "source_id" => SecureRandom.uuid,
        "source_user_id" => user_source_id,
        "roles" => [],
        "created_at" => Time.current.iso8601,
        "updated_at" => Time.current.iso8601,
      }]))

      %w[notes.json decisions.json options.json decision_participants.json
         votes.json decision_audit_entries.json commitments.json
         commitment_participants.json links.json note_history_events.json].each do |f|
        zos.put_next_entry("export/#{f}")
        zos.write("[]")
      end
    end

    path.to_s
  end

  teardown do
    @synthetic_zip_paths&.each { |p| FileUtils.rm_f(p) }
  end
end
