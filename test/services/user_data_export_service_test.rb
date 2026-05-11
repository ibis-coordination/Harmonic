# typed: false

require "test_helper"
require "zip"

class UserDataExportServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @tenant.update!(main_collective: @collective) if @tenant.main_collective_id.nil?

    @other_user = create_user(name: "Other User")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)

    @data_export = DataExport.create!(
      tenant: @tenant,
      collective: @collective,
      user: @user,
      status: "pending",
      export_type: "user",
    )
  end

  test "marks the export completed and attaches a file" do
    UserDataExportService.new(data_export: @data_export).perform!

    @data_export.reload
    assert_equal "completed", @data_export.status
    assert @data_export.file.attached?
    assert @data_export.completed_at.present?
    assert @data_export.expires_at.present?
  end

  test "notes.json includes the subject user's notes and excludes others" do
    my_note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Mine", text: "by me",
    )
    create_note(
      tenant: @tenant, collective: @collective, created_by: @other_user,
      title: "Theirs", text: "by them",
    )

    UserDataExportService.new(data_export: @data_export).perform!

    notes = read_json_from_zip("notes.json")
    source_ids = notes.map { |n| n["source_id"] }
    assert_includes source_ids, my_note.id
    refute notes.any? { |n| n["title"] == "Theirs" }, "exports another user's note: #{notes.inspect}"
  end

  test "manifest declares export_type as 'user' and identifies the subject" do
    UserDataExportService.new(data_export: @data_export).perform!

    manifest = read_json_from_zip("manifest.json")
    assert_equal "user", manifest["export_type"]
    assert_equal @user.id, manifest["subject"]["user_id"]
    assert_equal @collective.id, manifest["subject"]["collective_id"]
  end

  test "produces a valid ZIP with empty arrays when the user has no activity" do
    # No content created by @user; the only seeded record is the user themself.
    UserDataExportService.new(data_export: @data_export).perform!

    @data_export.reload
    assert_equal "completed", @data_export.status

    notes = read_json_from_zip("notes.json")
    assert_equal [], notes
  end

  test "refuses to run when DataExport.export_type is not 'user'" do
    @data_export.update_columns(export_type: "collective")
    assert_raises(ArgumentError) do
      UserDataExportService.new(data_export: @data_export)
    end
  end

  test "refuses to run when the collective is not the tenant's main collective" do
    other_collective = create_collective(tenant: @tenant, created_by: @user, name: "Other", handle: "other-#{SecureRandom.hex(4)}")
    other_collective.add_user!(@user)
    export = DataExport.create!(
      tenant: @tenant, collective: other_collective, user: @user,
      status: "pending", export_type: "user",
    )
    assert_raises(ArgumentError, /main collective/i) do
      UserDataExportService.new(data_export: export)
    end
  end

  test "refuses to run when the subject user is not a human" do
    ai_agent = create_ai_agent(parent: @user)
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: ai_agent,
      status: "pending", export_type: "user",
    )
    assert_raises(ArgumentError, /human/i) do
      UserDataExportService.new(data_export: export)
    end
  end

  test "decisions.json includes only decisions authored by the subject" do
    mine = create_decision(tenant: @tenant, collective: @collective, created_by: @user, question: "Mine")
    create_decision(tenant: @tenant, collective: @collective, created_by: @other_user, question: "Theirs")

    UserDataExportService.new(data_export: @data_export).perform!

    decisions = read_json_from_zip("decisions.json")
    source_ids = decisions.map { |d| d["source_id"] }
    assert_includes source_ids, mine.id
    refute decisions.any? { |d| d["question"] == "Theirs" }
  end

  test "options.json includes only options proposed by the subject" do
    others_decision = create_decision(tenant: @tenant, collective: @collective, created_by: @other_user)
    my_option = create_option(decision: others_decision, created_by: @user, title: "Mine")
    create_option(decision: others_decision, created_by: @other_user, title: "Theirs")

    UserDataExportService.new(data_export: @data_export).perform!

    options = read_json_from_zip("options.json")
    source_ids = options.map { |o| o["source_id"] }
    assert_includes source_ids, my_option.id
    refute options.any? { |o| o["title"] == "Theirs" }
  end

  test "commitments.json includes only commitments authored by the subject" do
    mine = create_commitment(tenant: @tenant, collective: @collective, created_by: @user, title: "Mine")
    create_commitment(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Theirs")

    UserDataExportService.new(data_export: @data_export).perform!

    commitments = read_json_from_zip("commitments.json")
    source_ids = commitments.map { |c| c["source_id"] }
    assert_includes source_ids, mine.id
    refute commitments.any? { |c| c["title"] == "Theirs" }
  end

  test "votes.json includes only the subject's votes with denormalized option_title and decision_question" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @other_user, question: "Pizza or tacos?")
    option = create_option(decision: decision, created_by: @other_user, title: "Tacos")
    my_participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    other_participant = DecisionParticipantManager.new(decision: decision, user: @other_user).find_or_create_participant
    my_vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: decision, option: option,
      decision_participant: my_participant, accepted: 1, preferred: 0,
    )
    Vote.create!(
      tenant: @tenant, collective: @collective, decision: decision, option: option,
      decision_participant: other_participant, accepted: 1, preferred: 1,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    votes = read_json_from_zip("votes.json")
    assert_equal 1, votes.length, "should include exactly the subject's vote"
    v = votes.first
    assert_equal my_vote.id, v["source_id"]
    assert_equal "Tacos", v["option_title"], "denormalized option_title snapshot"
    assert_equal "Pizza or tacos?", v["decision_question"], "denormalized decision_question snapshot"
  end

  test "decision_participants.json includes only the subject's participations with denormalized decision_question" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @other_user, question: "Which way?")
    my_participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    DecisionParticipantManager.new(decision: decision, user: @other_user).find_or_create_participant

    UserDataExportService.new(data_export: @data_export).perform!

    participants = read_json_from_zip("decision_participants.json")
    assert_equal 1, participants.length
    p = participants.first
    assert_equal my_participant.id, p["source_id"]
    assert_equal "Which way?", p["decision_question"]
  end

  test "commitment_participants.json includes only the subject's participations with denormalized commitment_title" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Show up Saturday")
    my_cp = CommitmentParticipantManager.new(commitment: commitment, user: @user).find_or_create_participant
    my_cp.update!(committed_at: Time.current)
    other_cp = CommitmentParticipantManager.new(commitment: commitment, user: @other_user).find_or_create_participant
    other_cp.update!(committed_at: Time.current)

    UserDataExportService.new(data_export: @data_export).perform!

    participants = read_json_from_zip("commitment_participants.json")
    assert_equal 1, participants.length
    p = participants.first
    assert_equal my_cp.id, p["source_id"]
    assert_equal "Show up Saturday", p["commitment_title"]
  end

  test "decision_audit_entries.json includes entries where actor=subject with denormalized decision context" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @other_user, question: "What time?")
    option = create_option(decision: decision, created_by: @other_user, title: "Noon")
    my_participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    other_participant = DecisionParticipantManager.new(decision: decision, user: @other_user).find_or_create_participant

    my_vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: decision, option: option,
      decision_participant: my_participant, accepted: 1, preferred: 0,
    )
    DecisionAuditService.record_vote!(decision: decision, vote: my_vote, actor: @user)

    other_vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: decision, option: option,
      decision_participant: other_participant, accepted: 1, preferred: 0,
    )
    DecisionAuditService.record_vote!(decision: decision, vote: other_vote, actor: @other_user)

    UserDataExportService.new(data_export: @data_export).perform!

    entries = read_json_from_zip("decision_audit_entries.json")
    actor_ids = entries.map { |e| e["source_actor_id"] }
    assert_equal [@user.id], actor_ids.uniq, "should include only the subject's entries"

    entry = entries.first
    assert_equal "vote_cast", entry["action"]
    assert_equal "Noon", entry["option_title"]
    assert_equal "What time?", entry["decision_question"], "denormalized decision_question snapshot"
    assert_equal decision.truncated_id, entry["decision_truncated_id"], "needed to reconstruct the receipt URL"
    assert entry["entry_hash"].present?, "entry_hash present for the user's own receipt lookup"
  end

  test "users.json includes the subject and excludes other users" do
    UserDataExportService.new(data_export: @data_export).perform!

    users = read_json_from_zip("users.json")
    source_ids = users.map { |u| u["source_id"] }
    assert_equal [@user.id], source_ids
    me = users.first
    assert_equal @user.email, me["email"]
    assert_equal @user.name, me["name"]
    assert_equal "human", me["user_type"]
  end

  test "tenant_users.json includes the subject's TenantUser row in this tenant" do
    UserDataExportService.new(data_export: @data_export).perform!

    tu_rows = read_json_from_zip("tenant_users.json")
    source_ids = tu_rows.map { |t| t["source_id"] }
    expected = TenantUser.find_by!(tenant_id: @tenant.id, user_id: @user.id)
    assert_includes source_ids, expected.id
    assert_equal expected.handle, tu_rows.first["handle"]
    refute tu_rows.any? { |t| t["source_user_id"] == @other_user.id }, "must not include other users' TenantUser rows"
  end

  test "collective_members.json includes the subject's membership in the main collective" do
    UserDataExportService.new(data_export: @data_export).perform!

    members = read_json_from_zip("collective_members.json")
    user_ids = members.map { |m| m["source_user_id"] }
    assert_equal [@user.id], user_ids, "should include only the subject's membership"
  end

  test "oauth_identities.json includes provider linkages and excludes auth_data" do
    OauthIdentity.create!(
      user: @user, provider: "google_oauth2", uid: "12345",
      url: "https://example.com/alice", username: "alice",
      auth_data: { "access_token" => "SECRET", "refresh_token" => "SECRET2" },
    )

    UserDataExportService.new(data_export: @data_export).perform!

    rows = read_json_from_zip("oauth_identities.json")
    assert_equal 1, rows.length
    row = rows.first
    assert_equal "google_oauth2", row["provider"]
    assert_equal "12345", row["uid"]
    refute row.key?("auth_data"), "auth_data must NOT be exported (contains tokens)"
    serialized = row.to_json
    refute_includes serialized, "SECRET", "no access/refresh tokens leak via any field"
  end

  test "omni_auth_identities.json excludes password_digest, otp_secret, and recovery codes" do
    OmniAuthIdentity.create!(
      email: @user.email, name: @user.name,
      password: SecureRandom.hex(10),
      user: @user,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    rows = read_json_from_zip("omni_auth_identities.json")
    assert_equal 1, rows.length
    row = rows.first
    refute row.key?("password_digest"), "password_digest must NOT be exported"
    refute row.key?("otp_secret"), "otp_secret must NOT be exported"
    refute row.key?("otp_recovery_codes"), "recovery codes must NOT be exported"
    refute row.key?("reset_password_token"), "reset_password_token must NOT be exported"
    assert_equal @user.email, row["email"]
  end

  test "does not leak participations from other collectives in the same tenant" do
    other_collective = create_collective(tenant: @tenant, created_by: @user, name: "Private Group", handle: "private-#{SecureRandom.hex(4)}")
    other_collective.add_user!(@user)

    # User has a decision + participation + vote AND a commitment + participation in the OTHER collective.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: other_collective.handle)

    other_decision = create_decision(tenant: @tenant, collective: other_collective, created_by: @user, question: "Other group decision")
    other_option = create_option(decision: other_decision, created_by: @user, title: "Other option")
    other_participant = DecisionParticipantManager.new(decision: other_decision, user: @user).find_or_create_participant
    Vote.create!(
      tenant: @tenant, collective: other_collective, decision: other_decision, option: other_option,
      decision_participant: other_participant, accepted: 1, preferred: 0,
    )

    other_commitment = create_commitment(tenant: @tenant, collective: other_collective, created_by: @user, title: "Other commitment")
    other_cp = CommitmentParticipantManager.new(commitment: other_commitment, user: @user).find_or_create_participant
    other_cp.update!(committed_at: Time.current)

    # Switch back to the main collective scope and run the export.
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    UserDataExportService.new(data_export: @data_export).perform!

    decision_participants = read_json_from_zip("decision_participants.json")
    refute decision_participants.any? { |p| p["source_decision_id"] == other_decision.id },
           "decision_participants must not include participations from other collectives"

    votes = read_json_from_zip("votes.json")
    refute votes.any? { |v| v["source_decision_id"] == other_decision.id },
           "votes must not include votes from other collectives"

    commitment_participants = read_json_from_zip("commitment_participants.json")
    refute commitment_participants.any? { |p| p["source_commitment_id"] == other_commitment.id },
           "commitment_participants must not include participations from other collectives"
  end

  test "includes data authored by AI agent children of the subject" do
    ai_agent = create_ai_agent(parent: @user)
    @collective.add_user!(ai_agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    agent_note = create_note(tenant: @tenant, collective: @collective, created_by: ai_agent, title: "Agent note", text: "by agent")

    UserDataExportService.new(data_export: @data_export).perform!

    notes = read_json_from_zip("notes.json")
    source_ids = notes.map { |n| n["source_id"] }
    assert_includes source_ids, agent_note.id, "AI agent's note must appear in the parent's export"

    manifest = read_json_from_zip("manifest.json")
    assert_includes manifest["subject"]["ai_agent_user_ids"], ai_agent.id
  end

  test "attachments.json includes only attachments created by the subject, with binary content in the ZIP" do
    my_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "My note", text: "x")
    their_note = create_note(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Their note", text: "y")

    my_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("my secret thoughts"), filename: "mine.txt", content_type: "text/plain",
    )
    my_attachment = Attachment.create!(
      tenant: @tenant, collective: @collective, attachable: my_note, file: my_blob,
      created_by: @user, updated_by: @user,
    )

    their_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("not mine"), filename: "theirs.txt", content_type: "text/plain",
    )
    Attachment.create!(
      tenant: @tenant, collective: @collective, attachable: their_note, file: their_blob,
      created_by: @other_user, updated_by: @other_user,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    attachments = read_json_from_zip("attachments.json")
    source_ids = attachments.map { |a| a["source_id"] }
    assert_equal [my_attachment.id], source_ids, "must include only the subject's attachment"

    contents = read_file_from_zip("attachments/#{my_attachment.id}-mine.txt")
    assert_equal "my secret thoughts", contents, "binary content of subject's attachment must be in the ZIP"

    refute zip_contains?("attachments/#{my_blob.id}-theirs.txt"),
           "binary content of other user's attachment must NOT be in the ZIP"
  end

  test "note_history_events.json includes the subject's events (read confirmations, edits) on any note" do
    # Other user's note. Their create event is auto-recorded; subject reads it.
    their_note = create_note(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Theirs", text: "hi")
    my_read = NoteHistoryEvent.create!(
      tenant: @tenant, collective: @collective, note: their_note, user: @user,
      event_type: "read_confirmation", happened_at: Time.current,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    events = read_json_from_zip("note_history_events.json")
    source_ids = events.map { |e| e["source_id"] }
    assert_includes source_ids, my_read.id, "subject's read confirmation on another user's note must be included"
    refute events.any? { |e| e["source_user_id"] == @other_user.id }, "other users' events must be excluded"

    # Denormalized note context so the user can see WHAT they read
    my_entry = events.find { |e| e["source_id"] == my_read.id }
    assert_equal "Theirs", my_entry["note_title"], "denormalized note_title snapshot"
    assert_equal "read_confirmation", my_entry["event_type"]
  end

  test "invites.json includes only invites sent by the subject" do
    mine = Invite.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      code: SecureRandom.hex(8), expires_at: 1.week.from_now,
    )
    Invite.create!(
      tenant: @tenant, collective: @collective, created_by: @other_user,
      code: SecureRandom.hex(8), expires_at: 1.week.from_now,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    invites = read_json_from_zip("invites.json")
    source_ids = invites.map { |i| i["source_id"] }
    assert_equal [mine.id], source_ids, "only invites the subject sent are theirs to export"
  end

  test "representation_sessions.json includes only user-to-user sessions where subject is the representative" do
    # User representation (collective_id IS NULL, trustee_grant_id present): the
    # subject is acting on behalf of someone else via a trustee grant. This is
    # the only kind of representation in scope for the main-collective export —
    # the main collective itself has no representatives, and collective-rep
    # sessions only exist inside non-main collectives.
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @other_user, trustee_user: @user,
      description: "Trust subject to act for X", accepted_at: Time.current,
    )
    mine = RepresentationSession.create!(
      tenant: @tenant, collective_id: nil, trustee_grant: grant,
      representative_user: @user, began_at: Time.current, confirmed_understanding: true,
    )

    # Collective representation in some other (non-main) collective: excluded.
    other_collective = create_collective(tenant: @tenant, created_by: @other_user, name: "Other", handle: "other-#{SecureRandom.hex(4)}")
    other_collective.add_user!(@user)
    RepresentationSession.create!(
      tenant: @tenant, collective: other_collective,
      representative_user: @user, began_at: Time.current, confirmed_understanding: true,
    )

    # Another user's user-rep session: excluded.
    other_grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      description: "Trust other to act for subject", accepted_at: Time.current,
    )
    RepresentationSession.create!(
      tenant: @tenant, collective_id: nil, trustee_grant: other_grant,
      representative_user: @other_user, began_at: Time.current, confirmed_understanding: true,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    sessions = read_json_from_zip("representation_sessions.json")
    source_ids = sessions.map { |s| s["source_id"] }
    assert_equal [mine.id], source_ids
  end

  test "representation_session_events.json includes only events for the subject's user-rep sessions" do
    target_note = create_note(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Target", text: "x")
    my_grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @other_user, trustee_user: @user,
      description: "trust", accepted_at: Time.current,
    )
    my_session = RepresentationSession.create!(
      tenant: @tenant, collective_id: nil, trustee_grant: my_grant,
      representative_user: @user, began_at: Time.current, confirmed_understanding: true,
    )

    # Session for someone else's representation: events on it must be excluded.
    other_grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      description: "trust", accepted_at: Time.current,
    )
    other_session = RepresentationSession.create!(
      tenant: @tenant, collective_id: nil, trustee_grant: other_grant,
      representative_user: @other_user, began_at: Time.current, confirmed_understanding: true,
    )

    mine = RepresentationSessionEvent.create!(
      tenant: @tenant, representation_session: my_session,
      action_name: "read", resource: target_note, resource_collective_id: @collective.id,
    )
    RepresentationSessionEvent.create!(
      tenant: @tenant, representation_session: other_session,
      action_name: "read", resource: target_note, resource_collective_id: @collective.id,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    events = read_json_from_zip("representation_session_events.json")
    source_ids = events.map { |e| e["source_id"] }
    assert_equal [mine.id], source_ids, "only events in the subject's own user-rep sessions are included"
  end

  test "trustee_grants.json includes grants where subject is grantor or trustee" do
    granted_by_me = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      description: "Trust X to act for me",
    )
    granted_to_me = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @other_user, trustee_user: @user,
      description: "Trust subject to act for X",
    )
    unrelated_user = create_user(name: "Unrelated")
    @tenant.add_user!(unrelated_user)
    TrusteeGrant.create!(
      tenant: @tenant, granting_user: @other_user, trustee_user: unrelated_user,
      description: "Not about subject",
    )

    UserDataExportService.new(data_export: @data_export).perform!

    grants = read_json_from_zip("trustee_grants.json")
    source_ids = grants.map { |g| g["source_id"] }
    assert_includes source_ids, granted_by_me.id, "grant where subject is granting_user must be included"
    assert_includes source_ids, granted_to_me.id, "grant where subject is trustee_user must be included"
    assert_equal 2, source_ids.length, "third-party grants must be excluded"
  end

  test "agent_configuration is sliced to a fixed key allowlist — unknown sub-keys do not leak" do
    ai_agent = create_ai_agent(parent: @user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    # Simulate a future code path that stores a sensitive key on the AI agent.
    ai_agent.update_columns(
      agent_configuration: ai_agent.agent_configuration.to_h.merge("api_key" => "SHOULD_NOT_LEAK_ABCDE"),
    )

    UserDataExportService.new(data_export: @data_export).perform!

    users = read_json_from_zip("users.json")
    agent_row = users.find { |u| u["source_id"] == ai_agent.id }
    refute_nil agent_row
    refute agent_row["agent_configuration"].key?("api_key"),
           "agent_configuration must drop unknown keys; got: #{agent_row['agent_configuration'].inspect}"
    refute_includes agent_row.to_json, "SHOULD_NOT_LEAK_ABCDE"
  end

  test "TenantUser.settings is sliced — unknown sub-keys do not leak" do
    tu = @user.tenant_users.find_by!(tenant_id: @tenant.id)
    tu.update_columns(settings: tu.settings.to_h.merge("future_secret" => "SETTINGS_LEAK_XYZ"))

    UserDataExportService.new(data_export: @data_export).perform!

    rows = read_json_from_zip("tenant_users.json")
    me = rows.find { |r| r["source_user_id"] == @user.id }
    refute me["settings"].key?("future_secret"), "TenantUser settings must drop unknown keys"
    refute_includes me.to_json, "SETTINGS_LEAK_XYZ"
  end

  test "CollectiveMember.settings is sliced — unknown sub-keys do not leak" do
    cm = @collective.collective_members.find_by!(user_id: @user.id)
    cm.update_columns(settings: cm.settings.to_h.merge("future_secret" => "MEMBER_LEAK_QPR"))

    UserDataExportService.new(data_export: @data_export).perform!

    rows = read_json_from_zip("collective_members.json")
    me = rows.find { |r| r["source_user_id"] == @user.id }
    refute me["settings"].key?("future_secret"), "CollectiveMember settings must drop unknown keys"
    refute_includes me.to_json, "MEMBER_LEAK_QPR"
  end

  test "credential strings do not appear in any exported JSON file (sweep across the whole ZIP)" do
    # Plant a unique sentinel into every place credentials might live, then
    # assert the ZIP contains none of them. Catches accidental leakage from
    # any future code path that adds a column without going through the
    # explicit per-record allowlist.
    omni = OmniAuthIdentity.create!(email: @user.email, name: @user.name, password: SecureRandom.hex(10), user: @user)
    omni.update_columns(
      password_digest: "PD_LEAK_X4Y9Z2",
      reset_password_token: "RP_LEAK_M7N3O8",
      otp_secret: "OS_LEAK_K2L9M4",
      otp_recovery_codes: ["RC_LEAK_R5T8W1"],
    )
    OauthIdentity.create!(
      user: @user, provider: "google_oauth2", uid: "12345",
      auth_data: { "access_token" => "AT_LEAK_J1K2L3", "refresh_token" => "RT_LEAK_Q9W8E7" },
    )
    ApiToken.create!(
      tenant: @tenant, user: @user, name: "test",
      scopes: ApiToken.valid_scopes,
    )

    UserDataExportService.new(data_export: @data_export).perform!

    zip_data = @data_export.file.download
    sentinels = %w[
      PD_LEAK_X4Y9Z2 RP_LEAK_M7N3O8 OS_LEAK_K2L9M4 RC_LEAK_R5T8W1
      AT_LEAK_J1K2L3 RT_LEAK_Q9W8E7
    ]
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        next unless entry.name.end_with?(".json")

        contents = io.read
        sentinels.each do |s|
          refute_includes contents, s, "credential sentinel '#{s}' leaked into #{entry.name}"
        end
      end
    end
  end

  test "trustee_grants.json includes AI agent's auto-created parent grant" do
    # create_ai_agent triggers User#create_parent_trustee_grant! which creates
    # a grant where granting_user = agent and trustee_user = parent. Both
    # users are in the subject set, so the grant appears in the parent's export.
    ai_agent = create_ai_agent(parent: @user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    UserDataExportService.new(data_export: @data_export).perform!

    grants = read_json_from_zip("trustee_grants.json")
    refute_empty grants, "AI agent auto-grant should appear in parent's export"
    grant = grants.first
    assert_equal ai_agent.id, grant["source_granting_user_id"]
    assert_equal @user.id, grant["source_trustee_user_id"]
  end

  test "excludes soft-deleted content" do
    kept = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Kept", text: "x")
    deleted = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Deleted", text: "y")
    deleted.soft_delete!(by: @user)

    UserDataExportService.new(data_export: @data_export).perform!

    notes = read_json_from_zip("notes.json")
    source_ids = notes.map { |n| n["source_id"] }
    assert_includes source_ids, kept.id
    refute_includes source_ids, deleted.id, "soft-deleted notes must be excluded"
  end

  test "links.json includes links touching the subject's content (either endpoint)" do
    my_note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Mine A", text: "x")
    my_other = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Mine B", text: "y")
    their_note = create_note(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Theirs", text: "z")
    unrelated_a = create_note(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Other A", text: "a")
    unrelated_b = create_note(tenant: @tenant, collective: @collective, created_by: @other_user, title: "Other B", text: "b")

    outbound = Link.create!(tenant: @tenant, collective: @collective, from_linkable: my_note, to_linkable: their_note)
    inbound = Link.create!(tenant: @tenant, collective: @collective, from_linkable: their_note, to_linkable: my_other)
    unrelated = Link.create!(tenant: @tenant, collective: @collective, from_linkable: unrelated_a, to_linkable: unrelated_b)

    UserDataExportService.new(data_export: @data_export).perform!

    links = read_json_from_zip("links.json")
    source_ids = links.map { |l| l["source_id"] }
    assert_includes source_ids, outbound.id, "outbound link from subject's note must be included"
    assert_includes source_ids, inbound.id, "inbound link to subject's note must be included"
    refute_includes source_ids, unrelated.id, "links between others' content must be excluded"
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

  def read_file_from_zip(suffix)
    zip_data = @data_export.file.download
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        return io.read if entry.name.end_with?(suffix)
      end
    end
    raise "#{suffix} not found in ZIP"
  end

  def zip_contains?(suffix)
    zip_data = @data_export.file.download
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        return true if entry.name.end_with?(suffix)
      end
    end
    false
  end
end
