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
end
