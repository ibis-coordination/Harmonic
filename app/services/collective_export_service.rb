# typed: true

require "zip"

class CollectiveExportService
  extend T::Sig

  sig { params(data_export: DataExport).void }
  def initialize(data_export:)
    @data_export = data_export
    @collective = T.let(T.must(data_export.collective), Collective)
    @tenant = T.let(T.must(data_export.tenant), Tenant)
    @record_counts = T.let({}, T::Hash[String, Integer])
    @checksums = T.let({}, T::Hash[String, String])
  end

  sig { void }
  def perform!
    @data_export.update!(status: "processing", started_at: Time.current)

    with_scoped_context do
      Dir.mktmpdir("harmonic-export") do |tmpdir|
        gather_collective(tmpdir)
        gather_users(tmpdir)
        gather_members(tmpdir)
        gather_notes(tmpdir)
        gather_decisions(tmpdir)
        gather_options(tmpdir)
        gather_decision_participants(tmpdir)
        gather_votes(tmpdir)
        gather_decision_audit_entries(tmpdir)
        gather_commitments(tmpdir)
        gather_commitment_participants(tmpdir)
        gather_links(tmpdir)
        gather_note_history_events(tmpdir)
        gather_invites(tmpdir)
        gather_heartbeats(tmpdir)
        gather_representation_sessions(tmpdir)
        gather_representation_session_events(tmpdir)
        gather_attachments(tmpdir)
        write_manifest(tmpdir)

        zip_path = create_zip(tmpdir)
        begin
          @data_export.file.attach(
            io: File.open(zip_path),
            filename: zip_filename,
            content_type: "application/zip"
          )
        ensure
          FileUtils.rm_f(zip_path)
        end
      end
    end

    @data_export.update!(
      status: "completed",
      completed_at: Time.current,
      expires_at: 7.days.from_now,
      record_counts: @record_counts
    )
  rescue StandardError => e
    # update_columns avoids persisting any dirty in-memory attributes that
    # may have been set by a now-failed gather/attach step.
    @data_export.update_columns(status: "failed", error_message: e.message, updated_at: Time.current)
    raise
  end

  private

  # --- Gathering methods ---

  sig { params(tmpdir: String).void }
  def gather_collective(tmpdir)
    data = {
      "source_id" => @collective.id,
      "name" => @collective.name,
      "handle" => @collective.handle,
      "collective_type" => @collective.collective_type,
      "description" => @collective.description,
      "settings" => @collective.settings,
      "source_created_by_id" => @collective.created_by_id,
      "created_at" => @collective.created_at.iso8601,
      "updated_at" => @collective.updated_at.iso8601,
      "archived_at" => @collective.archived_at&.iso8601,
    }
    write_json(tmpdir, "collective.json", data)
  end

  # Emit only fields that are already visible to other collective members.
  #
  # PRIVACY: User email addresses are intentionally NOT exported. Within
  # Harmonic, a member's email is private — never displayed to other
  # members, only known to the user themselves. Including emails in an
  # export would let a collective admin extract member emails they were
  # never authorized to see in-app, which is a privacy boundary the
  # admin should not be able to cross unilaterally.
  #
  # Without email, cross-instance imports cannot auto-correlate users.
  # The import side handles this by:
  #   1. UUID match against existing users on the target instance
  #      (works for same-instance imports)
  #   2. Optional handle→email map provided by the importing tenant admin
  #      (for cross-instance migrations where the admin already has the
  #      emails through some legitimate channel)
  #   3. Fallback: create placeholder users
  sig { params(tmpdir: String).void }
  def gather_users(tmpdir)
    user_ids = collect_referenced_user_ids
    users = User.where(id: user_ids.to_a)
    tenant_users_by_user_id = TenantUser.where(tenant_id: @tenant.id, user_id: user_ids.to_a).index_by(&:user_id)
    data = users.map do |user|
      tenant_user = tenant_users_by_user_id[user.id]
      {
        "source_id" => user.id,
        "name" => user.name,
        "user_type" => user.user_type,
        "handle" => tenant_user&.handle,
      }
    end
    write_json(tmpdir, "users.json", data)
    @record_counts["users"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_members(tmpdir)
    members = CollectiveMember.where(collective_id: @collective.id)
    data = members.map do |m|
      {
        "source_id" => m.id,
        "source_user_id" => m.user_id,
        "roles" => m.roles,
        "archived_at" => m.archived_at&.iso8601,
        "created_at" => m.created_at.iso8601,
        "updated_at" => m.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "members.json", data)
    @record_counts["members"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_notes(tmpdir)
    notes = Note.with_deleted.where(collective_id: @collective.id)
    data = notes.map do |n|
      {
        "source_id" => n.id,
        "truncated_id" => n.truncated_id,
        "subtype" => n.subtype,
        "title" => n.title,
        "text" => n.text,
        "edit_access" => n.edit_access,
        "table_data" => n.table_data,
        "deadline" => n.deadline&.iso8601,
        "reminder_scheduled_for" => n.reminder_scheduled_for&.iso8601,
        "source_created_by_id" => n.created_by_id,
        "source_updated_by_id" => n.updated_by_id,
        "source_commentable_type" => n.commentable_type,
        "source_commentable_id" => n.commentable_id,
        "source_statementable_type" => n.statementable_type,
        "source_statementable_id" => n.statementable_id,
        "deleted_at" => n.deleted_at&.iso8601,
        "source_deleted_by_id" => n.deleted_by_id,
        "created_at" => n.created_at.iso8601,
        "updated_at" => n.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "notes.json", data)
    @record_counts["notes"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_decisions(tmpdir)
    decisions = Decision.with_deleted.where(collective_id: @collective.id)
    data = decisions.map do |d|
      {
        "source_id" => d.id,
        "truncated_id" => d.truncated_id,
        "subtype" => d.subtype,
        "question" => d.question,
        "description" => d.description,
        "options_open" => d.options_open,
        "deadline" => d.deadline&.iso8601,
        "source_created_by_id" => d.created_by_id,
        "source_updated_by_id" => d.updated_by_id,
        "source_decision_maker_id" => d.decision_maker_id,
        "lottery_beacon_round" => d.lottery_beacon_round,
        "lottery_beacon_randomness" => d.lottery_beacon_randomness,
        "audit_chain_hash" => d.audit_chain_hash,
        "deadline_event_fired_at" => d.deadline_event_fired_at&.iso8601,
        "deleted_at" => d.deleted_at&.iso8601,
        "source_deleted_by_id" => d.deleted_by_id,
        "created_at" => d.created_at.iso8601,
        "updated_at" => d.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "decisions.json", data)
    @record_counts["decisions"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_options(tmpdir)
    decision_ids = Decision.with_deleted.where(collective_id: @collective.id).pluck(:id)
    options = Option.where(decision_id: decision_ids)
    data = options.map do |o|
      {
        "source_id" => o.id,
        "source_decision_id" => o.decision_id,
        "source_decision_participant_id" => o.decision_participant_id,
        "title" => o.title,
        "description" => o.description,
        "random_id" => o.random_id,
        "created_at" => o.created_at.iso8601,
        "updated_at" => o.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "options.json", data)
    @record_counts["options"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_decision_participants(tmpdir)
    decision_ids = Decision.with_deleted.where(collective_id: @collective.id).pluck(:id)
    participants = DecisionParticipant.where(decision_id: decision_ids)
    data = participants.map do |p|
      {
        "source_id" => p.id,
        "source_decision_id" => p.decision_id,
        "source_user_id" => p.user_id,
        "vote_receipt_email" => p.vote_receipt_email,
        "created_at" => p.created_at.iso8601,
        "updated_at" => p.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "decision_participants.json", data)
    @record_counts["decision_participants"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_votes(tmpdir)
    decision_ids = Decision.with_deleted.where(collective_id: @collective.id).pluck(:id)
    votes = Vote.where(decision_id: decision_ids)
    data = votes.map do |v|
      {
        "source_id" => v.id,
        "source_decision_id" => v.decision_id,
        "source_option_id" => v.option_id,
        "source_decision_participant_id" => v.decision_participant_id,
        "accepted" => v.accepted,
        "preferred" => v.preferred,
        "created_at" => v.created_at.iso8601,
        "updated_at" => v.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "votes.json", data)
    @record_counts["votes"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_decision_audit_entries(tmpdir)
    decision_ids = Decision.with_deleted.where(collective_id: @collective.id).pluck(:id)
    entries = DecisionAuditEntry.where(decision_id: decision_ids).order(:decision_id, :sequence_number)
    data = entries.map do |e|
      {
        "source_id" => e.id,
        "source_decision_id" => e.decision_id,
        "sequence_number" => e.sequence_number,
        "schema_version" => e.schema_version,
        "action" => e.action,
        "source_actor_id" => e.actor_id,
        "actor_handle" => e.actor_handle,
        "actor_token" => e.actor_token,
        "actor_token_salt" => e.actor_token_salt,
        "option_title" => e.option_title,
        "accepted" => e.accepted,
        "preferred" => e.preferred,
        "metadata" => e.metadata,
        "previous_hash" => e.previous_hash,
        "entry_hash" => e.entry_hash,
        "created_at" => e.created_at.iso8601,
      }
    end
    write_json(tmpdir, "decision_audit_entries.json", data)
    @record_counts["decision_audit_entries"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_commitments(tmpdir)
    commitments = Commitment.with_deleted.where(collective_id: @collective.id)
    data = commitments.map do |c|
      {
        "source_id" => c.id,
        "truncated_id" => c.truncated_id,
        "subtype" => c.subtype,
        "title" => c.title,
        "description" => c.description,
        "critical_mass" => c.critical_mass,
        "limit" => c.limit,
        "deadline" => c.deadline&.iso8601,
        "source_created_by_id" => c.created_by_id,
        "source_updated_by_id" => c.updated_by_id,
        "deadline_event_fired_at" => c.deadline_event_fired_at&.iso8601,
        "deleted_at" => c.deleted_at&.iso8601,
        "source_deleted_by_id" => c.deleted_by_id,
        "created_at" => c.created_at.iso8601,
        "updated_at" => c.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "commitments.json", data)
    @record_counts["commitments"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_commitment_participants(tmpdir)
    commitment_ids = Commitment.with_deleted.where(collective_id: @collective.id).pluck(:id)
    participants = CommitmentParticipant.where(commitment_id: commitment_ids)
    data = participants.map do |p|
      {
        "source_id" => p.id,
        "source_commitment_id" => p.commitment_id,
        "source_user_id" => p.user_id,
        "committed_at" => p.committed_at&.iso8601,
        "created_at" => p.created_at.iso8601,
        "updated_at" => p.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "commitment_participants.json", data)
    @record_counts["commitment_participants"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_links(tmpdir)
    links = Link.where(collective_id: @collective.id)
    data = links.map do |l|
      {
        "source_id" => l.id,
        "from_linkable_type" => l.from_linkable_type,
        "source_from_linkable_id" => l.from_linkable_id,
        "to_linkable_type" => l.to_linkable_type,
        "source_to_linkable_id" => l.to_linkable_id,
        "created_at" => l.created_at.iso8601,
        "updated_at" => l.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "links.json", data)
    @record_counts["links"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_note_history_events(tmpdir)
    note_ids = Note.with_deleted.where(collective_id: @collective.id).pluck(:id)
    events = NoteHistoryEvent.where(note_id: note_ids)
    data = events.map do |e|
      {
        "source_id" => e.id,
        "source_note_id" => e.note_id,
        "source_user_id" => e.user_id,
        "event_type" => e.event_type,
        "happened_at" => e.happened_at&.iso8601,
        "created_at" => e.created_at.iso8601,
        "updated_at" => e.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "note_history_events.json", data)
    @record_counts["note_history_events"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_invites(tmpdir)
    invites = Invite.where(collective_id: @collective.id).where("expires_at > ? OR expires_at IS NULL", Time.current)
    data = invites.map do |i|
      {
        "source_id" => i.id,
        "source_created_by_id" => i.created_by_id,
        "source_invited_user_id" => i.invited_user_id,
        "code" => i.code,
        "expires_at" => i.expires_at.iso8601,
        "created_at" => i.created_at.iso8601,
        "updated_at" => i.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "invites.json", data)
    @record_counts["invites"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_heartbeats(tmpdir)
    heartbeats = Heartbeat.where(collective_id: @collective.id)
    data = heartbeats.map do |h|
      {
        "source_id" => h.id,
        "source_user_id" => h.user_id,
        "expires_at" => h.expires_at.iso8601,
        "activity_log" => h.activity_log,
        "created_at" => h.created_at.iso8601,
        "updated_at" => h.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "heartbeats.json", data)
    @record_counts["heartbeats"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_representation_sessions(tmpdir)
    sessions = RepresentationSession.where(collective_id: @collective.id)
    data = sessions.map do |s|
      {
        "source_id" => s.id,
        "truncated_id" => s.truncated_id,
        "source_representative_user_id" => s.representative_user_id,
        "source_trustee_grant_id" => s.trustee_grant_id,
        "began_at" => s.began_at.iso8601,
        "ended_at" => s.ended_at&.iso8601,
        "confirmed_understanding" => s.confirmed_understanding,
        "created_at" => s.created_at.iso8601,
        "updated_at" => s.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "representation_sessions.json", data)
    @record_counts["representation_sessions"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_representation_session_events(tmpdir)
    session_ids = RepresentationSession.where(collective_id: @collective.id).pluck(:id)
    events = RepresentationSessionEvent.where(representation_session_id: session_ids)
    data = events.map do |e|
      {
        "source_id" => e.id,
        "source_representation_session_id" => e.representation_session_id,
        "action_name" => e.action_name,
        "resource_type" => e.resource_type,
        "source_resource_id" => e.resource_id,
        "context_resource_type" => e.context_resource_type,
        "source_context_resource_id" => e.context_resource_id,
        "source_resource_collective_id" => e.resource_collective_id,
        "created_at" => e.created_at.iso8601,
        "updated_at" => e.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "representation_session_events.json", data)
    @record_counts["representation_session_events"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_attachments(tmpdir)
    attachments = Attachment.where(collective_id: @collective.id)
    attachments_dir = File.join(tmpdir, "attachments")
    FileUtils.mkdir_p(attachments_dir)

    data = attachments.map do |a|
      # Download blob to disk
      if a.file.attached?
        filename = "#{a.id}-#{a.name}"
        File.open(File.join(attachments_dir, filename), "wb") do |f|
          T.unsafe(a.file).download { |chunk| f.write(chunk) }
        end
      end

      {
        "source_id" => a.id,
        "attachable_type" => a.attachable_type,
        "source_attachable_id" => a.attachable_id,
        "source_created_by_id" => a.created_by_id,
        "source_updated_by_id" => a.updated_by_id,
        "name" => a.name,
        "content_type" => a.content_type,
        "byte_size" => a.byte_size,
        "filename" => a.file.attached? ? "#{a.id}-#{a.name}" : nil,
        "created_at" => a.created_at.iso8601,
        "updated_at" => a.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "attachments.json", data)
    @record_counts["attachments"] = data.length
  end

  # --- Helpers ---

  sig { returns(Set) }
  def collect_referenced_user_ids
    ids = Set.new
    collective_id = @collective.id

    # Collective creator
    ids << @collective.created_by_id

    # Members
    CollectiveMember.where(collective_id: collective_id).pluck(:user_id).each { |id| ids << id }

    # Content creators
    Note.with_deleted.where(collective_id: collective_id).pluck(:created_by_id, :updated_by_id).flatten.compact.each { |id| ids << id }
    Decision.with_deleted.where(collective_id: collective_id).pluck(:created_by_id, :updated_by_id, :decision_maker_id).flatten.compact.each { |id| ids << id }
    Commitment.with_deleted.where(collective_id: collective_id).pluck(:created_by_id, :updated_by_id).flatten.compact.each { |id| ids << id }

    # Participants (may not be members)
    decision_ids = Decision.with_deleted.where(collective_id: collective_id).pluck(:id)
    DecisionParticipant.where(decision_id: decision_ids).pluck(:user_id).each { |id| ids << id }
    commitment_ids = Commitment.with_deleted.where(collective_id: collective_id).pluck(:id)
    CommitmentParticipant.where(commitment_id: commitment_ids).pluck(:user_id).each { |id| ids << id }

    # Activity users
    note_ids = Note.with_deleted.where(collective_id: collective_id).pluck(:id)
    NoteHistoryEvent.where(note_id: note_ids).pluck(:user_id).compact.each { |id| ids << id }
    Heartbeat.where(collective_id: collective_id).pluck(:user_id).each { |id| ids << id }

    # Representation sessions
    RepresentationSession.where(collective_id: collective_id).pluck(:representative_user_id).each { |id| ids << id }

    # Invites
    Invite.where(collective_id: collective_id).pluck(:created_by_id, :invited_user_id).flatten.compact.each { |id| ids << id }

    # Attachments
    Attachment.where(collective_id: collective_id).pluck(:created_by_id, :updated_by_id).flatten.compact.each { |id| ids << id }

    ids
  end

  sig { params(tmpdir: String).void }
  def write_manifest(tmpdir)
    manifest = {
      "format_version" => "1.0",
      "app_version" => Rails.root.join("VERSION").read.strip,
      "exported_at" => Time.current.iso8601,
      "source_instance" => ENV.fetch("HOSTNAME", "unknown"),
      "source_subdomain" => @tenant.subdomain,
      "collective" => {
        "name" => @collective.name,
        "handle" => @collective.handle,
      },
      "record_counts" => @record_counts,
      "checksums" => @checksums,
    }
    write_json(tmpdir, "manifest.json", manifest)
  end

  sig { params(tmpdir: String, filename: String, data: T.untyped).void }
  def write_json(tmpdir, filename, data)
    path = File.join(tmpdir, filename)
    json = JSON.pretty_generate(data)
    File.write(path, json)
    @checksums[filename] = "sha256:#{Digest::SHA256.hexdigest(json)}"
  end

  sig { params(tmpdir: String).returns(String) }
  def create_zip(tmpdir)
    zip_path = File.join(Dir.tmpdir, zip_filename)
    prefix = zip_dirname

    Zip::OutputStream.open(zip_path) do |zos|
      Dir.glob(File.join(tmpdir, "**", "*")).each do |file_path|
        next if File.directory?(file_path)

        relative_path = file_path.sub("#{tmpdir}/", "")
        zos.put_next_entry("#{prefix}/#{relative_path}")
        File.open(file_path, "rb") do |f|
          buf = +""
          zos.write(buf) while f.read(65_536, buf)
        end
      end
    end

    zip_path
  end

  sig { returns(String) }
  def zip_dirname
    "harmonic-collective-export-#{Date.current.iso8601}-#{@data_export.id[0..7]}"
  end

  sig { returns(String) }
  def zip_filename
    "#{zip_dirname}.zip"
  end

  sig { params(block: T.proc.void).void }
  def with_scoped_context(&block)
    previous_tenant_id = Tenant.current_id
    previous_collective_id = Collective.current_id
    previous_collective_handle = Current.collective_handle
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    block.call
  ensure
    if previous_tenant_id
      Current.tenant_id = previous_tenant_id
      Current.collective_id = previous_collective_id
      Current.collective_handle = previous_collective_handle
    else
      Tenant.clear_thread_scope
      Collective.clear_thread_scope
    end
  end
end
