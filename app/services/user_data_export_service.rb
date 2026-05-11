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
        gather_commitment_participants(tmpdir)
        gather_links(tmpdir)
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
  sig { params(tmpdir: String).void }
  def gather_decision_participants(tmpdir)
    participants = DecisionParticipant.where(user_id: @subject_user_ids).includes(:decision)
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
    participant_ids = DecisionParticipant.where(user_id: @subject_user_ids).pluck(:id)
    votes = Vote.where(decision_participant_id: participant_ids).includes(:decision, :option)
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
    participants = CommitmentParticipant.where(user_id: @subject_user_ids).includes(:commitment)
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
