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
