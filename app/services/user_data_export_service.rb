# typed: true

require "zip"

# Per-user data export.
#
# Scope: the records that would be deleted or scrubbed on the parent user's
# account closure. Subject = parent user + every User row where
# `parent_id = user.id` (the user's AI agent children). Their data is
# included in the parent's export, not a separate one.
#
# See `.claude/plans/per-user-data-export.md` for the full design.
class UserDataExportService
  extend T::Sig

  sig { params(data_export: DataExport).void }
  def initialize(data_export:)
    @data_export = data_export
    raise ArgumentError, "expected export_type=user" unless data_export.export_type == "user"

    @user = T.let(T.must(data_export.user), User)
    @collective = T.let(T.must(data_export.collective), Collective)
    @tenant = T.let(T.must(data_export.tenant), Tenant)

    # v1 invariants: only human users export from the main collective. AI
    # agent and collective_identity users have their data included in their
    # parent's export rather than their own. Private collectives are
    # deferred pending ownership policy.
    unless @user.user_type == "human"
      raise ArgumentError, "subject user must be human (got user_type=#{@user.user_type.inspect})"
    end
    unless @tenant.main_collective_id == @collective.id
      raise ArgumentError, "v1 only supports export from the tenant's main collective"
    end

    @subject_user_ids = T.let(resolve_subject_user_ids, T::Array[String])
    @record_counts = T.let({}, T::Hash[String, Integer])
    @checksums = T.let({}, T::Hash[String, String])
  end

  sig { void }
  def perform!
    @data_export.update!(status: "processing", started_at: Time.current)

    with_scoped_context do
      Dir.mktmpdir("harmonic-user-export") do |tmpdir|
        gather_notes(tmpdir)
        gather_decisions(tmpdir)
        gather_options(tmpdir)
        gather_commitments(tmpdir)
        gather_decision_participants(tmpdir)
        gather_votes(tmpdir)
        gather_decision_audit_entries(tmpdir)
        gather_commitment_participants(tmpdir)
        gather_links(tmpdir)
        gather_users(tmpdir)
        gather_tenant_users(tmpdir)
        gather_collective_members(tmpdir)
        gather_oauth_identities(tmpdir)
        gather_omni_auth_identities(tmpdir)
        gather_attachments(tmpdir)
        write_manifest(tmpdir)

        zip_path = create_zip(tmpdir)
        begin
          @data_export.file.attach(
            io: File.open(zip_path),
            filename: zip_filename,
            content_type: "application/zip",
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
      record_counts: @record_counts,
    )
  rescue StandardError => e
    @data_export.update_columns(status: "failed", error_message: e.message, updated_at: Time.current)
    raise
  end

  private

  sig { returns(T::Array[String]) }
  def resolve_subject_user_ids
    ids = [@user.id]
    ids.concat(User.where(parent_id: @user.id).pluck(:id))
    ids.uniq
  end

  sig { params(tmpdir: String).void }
  def gather_notes(tmpdir)
    notes = Note.where(collective_id: @collective.id, created_by_id: @subject_user_ids)
    data = notes.map do |n|
      {
        "source_id" => n.id,
        "source_created_by_id" => n.created_by_id,
        "title" => n.title,
        "text" => n.text,
        "subtype" => n.subtype,
        "commentable_type" => n.commentable_type,
        "source_commentable_id" => n.commentable_id,
        "created_at" => n.created_at.iso8601,
        "updated_at" => n.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "notes.json", data)
    @record_counts["notes"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_decisions(tmpdir)
    decisions = Decision.where(collective_id: @collective.id, created_by_id: @subject_user_ids)
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
        "created_at" => d.created_at.iso8601,
        "updated_at" => d.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "decisions.json", data)
    @record_counts["decisions"] = data.length
  end

  # An Option is "authored by" the user who created its decision_participant.
  # Option doesn't have a direct created_by_id column — authorship flows through
  # the participant. This catches both creator-seeded options (the decision
  # creator is a participant) and participant-proposed options.
  sig { params(tmpdir: String).void }
  def gather_options(tmpdir)
    participant_ids = DecisionParticipant.where(user_id: @subject_user_ids).pluck(:id)
    options = Option.where(collective_id: @collective.id, decision_participant_id: participant_ids)
    data = options.map do |o|
      {
        "source_id" => o.id,
        "source_decision_id" => o.decision_id,
        "source_decision_participant_id" => o.decision_participant_id,
        "title" => o.title,
        "description" => o.description,
        "created_at" => o.created_at.iso8601,
        "updated_at" => o.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "options.json", data)
    @record_counts["options"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_commitments(tmpdir)
    commitments = Commitment.where(collective_id: @collective.id, created_by_id: @subject_user_ids)
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
        "created_at" => c.created_at.iso8601,
        "updated_at" => c.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "commitments.json", data)
    @record_counts["commitments"] = data.length
  end

  # Participation records: each carries a denormalized label snapshot
  # (decision_question / option_title / commitment_title) so the archive is
  # legible without including the parent records it points at. The snapshot
  # reflects the current label at export time; if the parent has been edited
  # since the user's action, the export reflects "what it's called now."
  #
  # The explicit `collective_id: @collective.id` filter is defense-in-depth.
  # The default scope inside `with_scoped_context` would filter anyway, but
  # callers that bypass that context would otherwise leak the user's
  # participations from other collectives in the same tenant. The user
  # exports from the main collective only; their data in other collectives
  # is not in scope.
  sig { params(tmpdir: String).void }
  def gather_decision_participants(tmpdir)
    participants = DecisionParticipant
                     .where(collective_id: @collective.id, user_id: @subject_user_ids)
                     .includes(:decision)
    data = participants.map do |p|
      decision = p.decision
      {
        "source_id" => p.id,
        "source_decision_id" => p.decision_id,
        "source_user_id" => p.user_id,
        "decision_question" => decision&.question,
        "created_at" => p.created_at.iso8601,
        "updated_at" => p.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "decision_participants.json", data)
    @record_counts["decision_participants"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_votes(tmpdir)
    participant_ids = DecisionParticipant
                        .where(collective_id: @collective.id, user_id: @subject_user_ids)
                        .pluck(:id)
    votes = Vote
              .where(collective_id: @collective.id, decision_participant_id: participant_ids)
              .includes(:decision, :option)
    data = votes.map do |v|
      decision = v.decision
      option = v.option
      {
        "source_id" => v.id,
        "source_decision_id" => v.decision_id,
        "source_option_id" => v.option_id,
        "source_decision_participant_id" => v.decision_participant_id,
        "accepted" => v.accepted,
        "preferred" => v.preferred,
        "option_title" => option&.title,
        "decision_question" => decision&.question,
        "created_at" => v.created_at.iso8601,
        "updated_at" => v.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "votes.json", data)
    @record_counts["votes"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_commitment_participants(tmpdir)
    participants = CommitmentParticipant
                     .where(collective_id: @collective.id, user_id: @subject_user_ids)
                     .includes(:commitment)
    data = participants.map do |p|
      commitment = p.commitment
      {
        "source_id" => p.id,
        "source_commitment_id" => p.commitment_id,
        "source_user_id" => p.user_id,
        "committed_at" => p.committed_at&.iso8601,
        "commitment_title" => commitment&.title,
        "created_at" => p.created_at.iso8601,
        "updated_at" => p.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "commitment_participants.json", data)
    @record_counts["commitment_participants"] = data.length
  end

  # Audit entries are included as receipts of the user's own actions, NOT as
  # a verifiable chain (the surrounding entries belong to the collective).
  # The user can verify any individual entry via the public receipt URL
  # using the entry_hash + decision_truncated_id snapshot.
  sig { params(tmpdir: String).void }
  def gather_decision_audit_entries(tmpdir)
    entries = DecisionAuditEntry.where(collective_id: @collective.id, actor_id: @subject_user_ids)
                                .includes(:decision)
                                .order(:decision_id, :sequence_number)
    data = entries.map do |e|
      decision = e.decision
      {
        "source_id" => e.id,
        "source_decision_id" => e.decision_id,
        "decision_truncated_id" => decision&.truncated_id,
        "decision_question" => decision&.question,
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

  # Links have no created_by column (they're relationship metadata). Include
  # links where either endpoint is content owned by the subject. Inbound
  # links from others' content to the subject's are included because they
  # disappear on account closure when the subject's content is deleted —
  # symmetric with the deletion-scope principle.
  sig { params(tmpdir: String).void }
  def gather_links(tmpdir)
    owned_note_ids = Note.where(collective_id: @collective.id, created_by_id: @subject_user_ids).pluck(:id)
    owned_decision_ids = Decision.where(collective_id: @collective.id, created_by_id: @subject_user_ids).pluck(:id)
    owned_commitment_ids = Commitment.where(collective_id: @collective.id, created_by_id: @subject_user_ids).pluck(:id)

    links = Link.where(collective_id: @collective.id).where(
      "(from_linkable_type = 'Note' AND from_linkable_id IN (:notes)) OR " \
      "(to_linkable_type = 'Note' AND to_linkable_id IN (:notes)) OR " \
      "(from_linkable_type = 'Decision' AND from_linkable_id IN (:decisions)) OR " \
      "(to_linkable_type = 'Decision' AND to_linkable_id IN (:decisions)) OR " \
      "(from_linkable_type = 'Commitment' AND from_linkable_id IN (:commitments)) OR " \
      "(to_linkable_type = 'Commitment' AND to_linkable_id IN (:commitments))",
      notes: owned_note_ids, decisions: owned_decision_ids, commitments: owned_commitment_ids,
    )
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

  # Account-level data. The parent user + AI agent children. Includes
  # personal data the user provided (email, name, avatar) and provider
  # linkages. Credentials (password digests, OTP secrets, OAuth tokens)
  # are excluded — they're not "personal data" in the GDPR Article 20
  # sense and exporting them would create an unnecessary attack surface
  # if the archive is intercepted.
  sig { params(tmpdir: String).void }
  def gather_users(tmpdir)
    users = User.where(id: @subject_user_ids)
    data = users.map do |u|
      {
        "source_id" => u.id,
        "email" => u.email,
        "name" => u.name,
        "user_type" => u.user_type,
        "source_parent_id" => u.parent_id,
        "picture_url" => u.picture_url,
        "image_url" => u.image_url,
        "agent_configuration" => u.agent_configuration,
        "created_at" => u.created_at.iso8601,
        "updated_at" => u.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "users.json", data)
    @record_counts["users"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_tenant_users(tmpdir)
    rows = TenantUser.where(tenant_id: @tenant.id, user_id: @subject_user_ids)
    data = rows.map do |t|
      {
        "source_id" => t.id,
        "source_user_id" => t.user_id,
        "handle" => t.handle,
        "display_name" => t.display_name,
        "settings" => t.settings,
        "archived_at" => t.archived_at&.iso8601,
        "created_at" => t.created_at.iso8601,
        "updated_at" => t.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "tenant_users.json", data)
    @record_counts["tenant_users"] = data.length
  end

  sig { params(tmpdir: String).void }
  def gather_collective_members(tmpdir)
    rows = CollectiveMember.where(collective_id: @collective.id, user_id: @subject_user_ids)
    data = rows.map do |m|
      {
        "source_id" => m.id,
        "source_user_id" => m.user_id,
        "settings" => m.settings,
        "roles" => m.roles,
        "archived_at" => m.archived_at&.iso8601,
        "created_at" => m.created_at.iso8601,
        "updated_at" => m.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "collective_members.json", data)
    @record_counts["collective_members"] = data.length
  end

  # OAuth provider linkages. The `auth_data` jsonb column carries access
  # and refresh tokens — those are credentials, not personal data, and are
  # NEVER exported.
  sig { params(tmpdir: String).void }
  def gather_oauth_identities(tmpdir)
    rows = OauthIdentity.where(user_id: @subject_user_ids)
    data = rows.map do |o|
      {
        "source_id" => o.id,
        "source_user_id" => o.user_id,
        "provider" => o.provider,
        "uid" => o.uid,
        "url" => o.url,
        "username" => o.username,
        "image_url" => o.image_url,
        "last_sign_in_at" => o.last_sign_in_at&.iso8601,
        "created_at" => o.created_at.iso8601,
        "updated_at" => o.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "oauth_identities.json", data)
    @record_counts["oauth_identities"] = data.length
  end

  # Email/password identity. The credential fields (password_digest,
  # otp_secret, otp_recovery_codes, reset_password_token) are NEVER
  # exported — they're credentials, not personal data, and including
  # them would create an unnecessary attack surface.
  sig { params(tmpdir: String).void }
  def gather_omni_auth_identities(tmpdir)
    rows = OmniAuthIdentity.where(user_id: @subject_user_ids)
    data = rows.map do |o|
      {
        "source_id" => o.id,
        "source_user_id" => o.user_id,
        "email" => o.email,
        "name" => o.name,
        "otp_enabled" => o.otp_enabled,
        "otp_enabled_at" => o.otp_enabled_at&.iso8601,
        "created_at" => o.created_at.iso8601,
        "updated_at" => o.updated_at.iso8601,
      }
    end
    write_json(tmpdir, "omni_auth_identities.json", data)
    @record_counts["omni_auth_identities"] = data.length
  end

  # Attachments owned by the subject. Binary content is written under
  # attachments/ in the ZIP; metadata in attachments.json. Attachments
  # created by others (even if attached to the subject's notes) are NOT
  # included — that's content the subject didn't create.
  sig { params(tmpdir: String).void }
  def gather_attachments(tmpdir)
    attachments = Attachment.where(collective_id: @collective.id, created_by_id: @subject_user_ids)
    attachments_dir = File.join(tmpdir, "attachments")
    FileUtils.mkdir_p(attachments_dir)

    data = attachments.map do |a|
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

  sig { params(tmpdir: String).void }
  def write_manifest(tmpdir)
    manifest = {
      "format_version" => "1.0",
      "export_type" => "user",
      "app_version" => Rails.root.join("VERSION").read.strip,
      "exported_at" => Time.current.iso8601,
      "source_instance" => ENV.fetch("HOSTNAME", "unknown"),
      "source_subdomain" => @tenant.subdomain,
      "subject" => {
        "user_id" => @user.id,
        "collective_id" => @collective.id,
        "ai_agent_user_ids" => (@subject_user_ids - [@user.id]),
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
    "harmonic-user-export-#{Date.current.iso8601}-#{@data_export.id[0..7]}"
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
