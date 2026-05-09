# typed: false

require "test_helper"
require "zip"

class CollectiveExportServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @data_export = DataExport.create!(
      tenant: @tenant,
      collective: @collective,
      user: @user,
      status: "pending",
    )
  end

  test "exports manifest with correct metadata" do
    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    @data_export.reload
    assert_equal "completed", @data_export.status
    assert @data_export.file.attached?
    assert @data_export.completed_at.present?
    assert @data_export.expires_at.present?

    manifest = read_json_from_zip("manifest.json")
    assert_equal "1.0", manifest["format_version"]
    assert_equal @collective.name, manifest["collective"]["name"]
    assert_equal @collective.handle, manifest["collective"]["handle"]
    assert manifest["exported_at"].present?
    assert manifest["checksums"].is_a?(Hash)
  end

  test "exports collective record" do
    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    collective_data = read_json_from_zip("collective.json")
    assert_equal @collective.id, collective_data["source_id"]
    assert_equal @collective.name, collective_data["name"]
    assert_equal @collective.handle, collective_data["handle"]
    assert_equal @collective.collective_type, collective_data["collective_type"]
  end

  test "exports users referenced by the collective" do
    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    users_data = read_json_from_zip("users.json")
    source_ids = users_data.map { |u| u["source_id"] }
    assert_includes source_ids, @user.id
  end

  test "users.json does not contain email addresses (privacy)" do
    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    users_data = read_json_from_zip("users.json")
    refute users_data.any? { |u| u.key?("email") }, "users.json must not include any email field"
  end

  test "exports members with roles" do
    member = @collective.collective_members.find_by(user_id: @user.id)
    member.add_role!("admin")

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    members_data = read_json_from_zip("members.json")
    assert_equal 1, members_data.length
    exported_member = members_data.first
    assert_equal @user.id, exported_member["source_user_id"]
    assert_includes exported_member["roles"], "admin"
  end

  test "exports notes" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Export Test", text: "Some content")

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    notes_data = read_json_from_zip("notes.json")
    assert_equal 1, notes_data.length
    assert_equal note.id, notes_data.first["source_id"]
    assert_equal "Export Test", notes_data.first["title"]
    assert_equal "Some content", notes_data.first["text"]
  end

  test "exports decisions with options and votes" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    option = create_option(decision: decision, created_by: @user, title: "Option A")
    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    vote = Vote.create!(tenant: @tenant, collective: @collective, decision: decision, option: option, decision_participant: participant, accepted: 1, preferred: 1)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    decisions_data = read_json_from_zip("decisions.json")
    assert_equal 1, decisions_data.length
    assert_equal decision.id, decisions_data.first["source_id"]

    options_data = read_json_from_zip("options.json")
    assert_equal 1, options_data.length
    assert_equal option.id, options_data.first["source_id"]

    votes_data = read_json_from_zip("votes.json")
    assert_equal 1, votes_data.length
    assert_equal 1, votes_data.first["accepted"]
    assert_equal 1, votes_data.first["preferred"]
  end

  test "exports commitments with participants" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    cp = CommitmentParticipant.create!(tenant: @tenant, collective: @collective, commitment: commitment, user: @user, committed_at: Time.current)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    commitments_data = read_json_from_zip("commitments.json")
    assert_equal 1, commitments_data.length
    assert_equal commitment.id, commitments_data.first["source_id"]

    participants_data = read_json_from_zip("commitment_participants.json")
    assert_equal 1, participants_data.length
    assert_equal cp.id, participants_data.first["source_id"]
  end

  test "exports soft-deleted items" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Will Delete")
    note.soft_delete!(by: @user)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    notes_data = read_json_from_zip("notes.json")
    assert_equal 1, notes_data.length
    assert notes_data.first["deleted_at"].present?
  end

  test "exports decision audit entries" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    option = create_option(decision: decision, created_by: @user, title: "Option A")
    DecisionAuditService.record_option!(decision: decision, option: option, actor: @user, action: "option_added")

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    audit_data = read_json_from_zip("decision_audit_entries.json")
    assert audit_data.length >= 1
    assert_equal "option_added", audit_data.first["action"]
    assert audit_data.first["entry_hash"].present?
  end

  test "exports note history events" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    history_data = read_json_from_zip("note_history_events.json")
    assert history_data.length >= 1
    assert_equal "create", history_data.first["event_type"]
  end

  test "exports links" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 1")
    note2 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 2")
    Link.create!(tenant: @tenant, collective: @collective, from_linkable: note1, to_linkable: note2)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    links_data = read_json_from_zip("links.json")
    assert_equal 1, links_data.length
    assert_equal "Note", links_data.first["from_linkable_type"]
  end

  test "exports heartbeats" do
    Heartbeat.create!(tenant: @tenant, collective: @collective, user: @user, expires_at: 5.minutes.from_now)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    heartbeats_data = read_json_from_zip("heartbeats.json")
    assert_equal 1, heartbeats_data.length
  end

  test "sets record_counts on data_export" do
    create_note(tenant: @tenant, collective: @collective, created_by: @user)
    create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 2")
    create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    @data_export.reload
    assert_equal 2, @data_export.record_counts["notes"]
    assert_equal 1, @data_export.record_counts["decisions"]
  end

  test "exports users referenced by participants, not just members" do
    # Create a second user who participates (votes) but is NOT a collective member
    voter = create_user(email: "voter-#{SecureRandom.hex(4)}@example.com", name: "External Voter")
    @tenant.add_user!(voter)
    # Don't add to collective — they participate directly
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    participant = DecisionParticipant.create!(tenant: @tenant, collective: @collective, decision: decision, user: voter)
    Vote.create!(tenant: @tenant, collective: @collective, decision: decision, option: create_option(decision: decision, created_by: @user, title: "Opt"), decision_participant: participant, accepted: 1, preferred: 0)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    users_data = read_json_from_zip("users.json")
    source_ids = users_data.map { |u| u["source_id"] }
    assert_includes source_ids, voter.id, "Voter user should be in users.json even though they're not a member"
  end

  test "exports invites that have not expired" do
    active_invite = Invite.create!(tenant: @tenant, collective: @collective, created_by: @user, code: "active123", expires_at: 1.week.from_now)
    expired_invite = Invite.create!(tenant: @tenant, collective: @collective, created_by: @user, code: "expired456", expires_at: 1.day.ago)

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    invites_data = read_json_from_zip("invites.json")
    codes = invites_data.map { |i| i["code"] }
    assert_includes codes, "active123"
    assert_not_includes codes, "expired456"
  end

  test "exports representation sessions and events" do
    # Need a trustee grant for the session
    session = RepresentationSession.create!(
      tenant: @tenant, collective: @collective,
      representative_user_id: @user.id,
      began_at: 1.hour.ago, ended_at: 30.minutes.ago,
      confirmed_understanding: true,
    )

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    sessions_data = read_json_from_zip("representation_sessions.json")
    assert_equal 1, sessions_data.length
    assert_equal @user.id, sessions_data.first["source_representative_user_id"]
    assert sessions_data.first["began_at"].present?
    assert sessions_data.first["ended_at"].present?
  end

  test "exports decision participants separately from votes" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    # Participant exists but no vote cast

    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    participants_data = read_json_from_zip("decision_participants.json")
    assert participants_data.length >= 1
    exported = participants_data.find { |p| p["source_decision_id"] == decision.id }
    assert_not_nil exported
    assert_equal @user.id, exported["source_user_id"]
  end

  test "exports empty collective without errors" do
    # The default setup has no content, just the collective and member
    service = CollectiveExportService.new(data_export: @data_export)
    service.perform!

    @data_export.reload
    assert_equal "completed", @data_export.status
    assert_equal 0, @data_export.record_counts.fetch("notes", 0)
    assert_equal 0, @data_export.record_counts.fetch("decisions", 0)
    assert_equal 0, @data_export.record_counts.fetch("commitments", 0)
  end

  test "marks export as failed on error" do
    service = CollectiveExportService.new(data_export: @data_export)

    # Force an error by redefining gather_notes on this instance
    def service.gather_notes(tmpdir)
      raise StandardError, "test explosion"
    end

    assert_raises(StandardError) { service.perform! }

    @data_export.reload
    assert_equal "failed", @data_export.status
    assert_equal "test explosion", @data_export.error_message
  end

  private

  def read_json_from_zip(filename)
    assert @data_export.file.attached?, "No file attached to data_export"
    zip_data = @data_export.file.download
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        if entry.name.end_with?("/#{filename}") || entry.name == filename
          return JSON.parse(io.read)
        end
      end
    end
    raise "#{filename} not found in ZIP"
  end
end
