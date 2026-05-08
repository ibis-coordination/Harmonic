# typed: true

require "zip"

class CollectiveImportService
  extend T::Sig

  sig { params(data_import: DataImport).void }
  def initialize(data_import:)
    @data_import = data_import
    @tenant = T.let(T.must(data_import.tenant), Tenant)
    @id_map = T.let({}, T::Hash[String, String])
    @user_mapping = T.let({}, T::Hash[String, T::Hash[String, T.untyped]])
    @record_counts = T.let({}, T::Hash[String, Integer])
    @zip_data = T.let({}, T::Hash[String, String])
    @notes_data = T.let(nil, T.untyped)
    @source_collective_id = T.let(nil, T.nilable(String))
  end

  sig { void }
  def perform!
    @data_import.update!(status: "validating", started_at: Time.current)

    extract_zip!
    validate_manifest!

    @data_import.update!(status: "importing")

    previous_tenant_id = Tenant.current_id
    previous_collective_id = Collective.current_id
    previous_collective_handle = Current.collective_handle

    begin
      ActiveRecord::Base.transaction do
        Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

        import_users
        import_collective
        import_members

        # Set collective scope for remaining imports
        collective = Collective.find(T.must(@data_import.collective_id))
        Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: collective.handle)

        import_notes_first_pass
        import_decisions
        import_commitments
        import_representation_sessions
        import_notes_second_pass  # comments/statements (need decisions/commitments/sessions in ID map)
        import_decision_participants
        import_options
        import_votes
        import_decision_audit_entries
        import_commitment_participants
        clear_auto_generated_history_events
        import_note_history_events
        import_heartbeats
        import_invites
        import_representation_session_events
        import_attachments
        rewrite_text_references
      end
    ensure
      restore_thread_scope(previous_tenant_id, previous_collective_id, previous_collective_handle)
    end

    @data_import.update!(
      status: "completed",
      completed_at: Time.current,
      record_counts: @record_counts,
      user_mapping: @user_mapping
    )
  rescue StandardError => e
    @data_import.update!(status: "failed", error_message: e.message)
    raise
  end

  private

  # --- ZIP handling ---

  sig { void }
  def extract_zip!
    raw = T.unsafe(@data_import.file).download
    Zip::InputStream.open(StringIO.new(raw)) do |io|
      while (entry = io.get_next_entry)
        next if entry.directory?

        # Strip the top-level directory prefix
        name = entry.name.sub(%r{^[^/]+/}, "")
        @zip_data[name] = io.read
      end
    end
  end

  sig { void }
  def validate_manifest!
    manifest = read_json("manifest.json")
    raise "Missing format_version in manifest" unless manifest["format_version"] == "1.0"

    @data_import.update!(source_manifest: manifest)
  end

  sig { params(filename: String).returns(T.untyped) }
  def read_json(filename)
    data = @zip_data[filename]
    raise "Missing file in export: #{filename}" unless data

    JSON.parse(data)
  end

  sig { params(filename: String).returns(T.untyped) }
  def read_json_optional(filename)
    data = @zip_data[filename]
    return [] unless data

    JSON.parse(data)
  end

  # --- ID mapping ---

  sig { params(source_id: T.nilable(String)).returns(T.nilable(String)) }
  def map_id(source_id)
    return nil if source_id.nil?

    @id_map[source_id]
  end

  sig { params(source_id: String).returns(String) }
  def map_id!(source_id)
    @id_map.fetch(source_id) { raise "Unmapped ID: #{source_id}" }
  end

  sig { params(source_id: String, new_id: String).void }
  def register_id(source_id, new_id)
    @id_map[source_id] = new_id
  end

  # --- Import methods ---

  sig { void }
  def import_users
    users_data = read_json("users.json")
    users_data.each do |u|
      existing = User.find_by(email: u["email"])
      if existing
        register_id(u["source_id"], existing.id)
        @user_mapping[u["email"]] = { "matched" => true, "target_user_id" => existing.id }
      else
        placeholder = User.create!(
          email: u["email"],
          name: u["name"],
          user_type: "imported_placeholder"
        )
        register_id(u["source_id"], placeholder.id)
        @user_mapping[u["email"]] = { "matched" => false, "target_user_id" => placeholder.id, "placeholder" => true }
      end
    end
    @record_counts["users"] = users_data.length
  end

  sig { void }
  def import_collective
    data = read_json("collective.json")
    @source_collective_id = data["source_id"]
    handle = unique_handle(data["handle"])
    collective = Collective.create!(
      tenant: @tenant,
      name: data["name"],
      handle: handle,
      collective_type: data["collective_type"] || "standard",
      description: data["description"],
      settings: data["settings"] || {},
      created_by_id: map_id(data["source_created_by_id"]) || @data_import.user_id
    )
    register_id(data["source_id"], collective.id)
    @data_import.update!(collective_id: collective.id)

    # Preserve timestamps
    collective.update_columns(
      created_at: Time.zone.parse(data["created_at"]),
      updated_at: Time.zone.parse(data["updated_at"])
    )
  end

  sig { void }
  def import_members
    members_data = read_json("members.json")
    collective = Collective.find(T.must(@data_import.collective_id))
    members_data.each do |m|
      user_id = map_id(m["source_user_id"])
      next unless user_id

      user = User.find(user_id)

      # Add user to tenant if not already
      tenant_user = TenantUser.find_by(tenant_id: @tenant.id, user_id: user_id)
      @tenant.add_user!(user) unless tenant_user

      member = collective.add_user!(user)
      register_id(m["source_id"], member.id)

      # Restore roles
      (m["roles"] || []).each do |role|
        member.add_role!(role)
      end

      # Preserve timestamps and archived state
      updates = {
        created_at: Time.zone.parse(m["created_at"]),
        updated_at: Time.zone.parse(m["updated_at"]),
      }
      updates[:archived_at] = Time.zone.parse(m["archived_at"]) if m["archived_at"]
      member.update_columns(updates)
    end
    @record_counts["members"] = members_data.length
  end

  sig { void }
  def import_notes_first_pass
    @notes_data = T.let(read_json("notes.json"), T.untyped)

    @notes_data.each do |n|
      next if ["comment", "statement"].include?(n["subtype"])

      note = Note.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        subtype: n["subtype"],
        title: n["title"],
        text: n["text"],
        edit_access: n["edit_access"],
        table_data: n["table_data"],
        deadline: n["deadline"] ? Time.zone.parse(n["deadline"]) : nil,
        reminder_scheduled_for: n["reminder_scheduled_for"] ? Time.zone.parse(n["reminder_scheduled_for"]) : nil,
        # reminder_notification_id intentionally NOT set — source notification doesn't exist in target
        created_by_id: map_id!(n["source_created_by_id"]),
        updated_by_id: map_id(n["source_updated_by_id"]) || map_id!(n["source_created_by_id"])
      )
      note.save!(validate: false)
      register_id(n["source_id"], note.id)

      preserve_timestamps(note, n)
      preserve_soft_delete(note, n)
    end
  end

  # Second pass: comments and statements. Runs after decisions, commitments, and
  # representation sessions are imported so that commentable_id/statementable_id
  # can be remapped. Uses iterative processing to handle arbitrarily deep nesting
  # (comment on comment on comment...) where parent comments are also in this pass.
  sig { void }
  def import_notes_second_pass
    pending = @notes_data.select { |n| ["comment", "statement"].include?(n["subtype"]) }
    max_iterations = pending.length + 1 # Safety bound to prevent infinite loops

    max_iterations.times do
      break if pending.empty?

      still_pending = []
      pending.each do |n|
        # Check if the parent is available in the ID map
        parent_id = if n["subtype"] == "comment" && n["source_commentable_id"]
          map_id(n["source_commentable_id"])
        elsif n["subtype"] == "statement" && n["source_statementable_id"]
          map_id(n["source_statementable_id"])
        end

        # If the parent references a Note (comment-on-comment) that hasn't been
        # created yet, defer this note to the next iteration
        if parent_id.nil? && n["source_commentable_type"] == "Note" && n["source_commentable_id"]
          still_pending << n
          next
        end

        import_single_comment_or_statement(n)
      end

      # If nothing was processed this iteration, we'd loop forever — break and
      # import remaining with nil parent (orphaned comments)
      if still_pending.length == pending.length
        still_pending.each { |n| import_single_comment_or_statement(n) }
        break
      end

      pending = still_pending
    end

    @record_counts["notes"] = @notes_data.length
  end

  sig { params(n: T::Hash[String, T.untyped]).void }
  def import_single_comment_or_statement(n)
    attrs = {
      tenant: @tenant,
      collective_id: @data_import.collective_id,
      subtype: n["subtype"],
      title: n["title"],
      text: n["text"],
      created_by_id: map_id!(n["source_created_by_id"]),
      updated_by_id: map_id(n["source_updated_by_id"]) || map_id!(n["source_created_by_id"]),
    }

    if n["subtype"] == "comment" && n["source_commentable_id"]
      attrs[:commentable_type] = n["source_commentable_type"]
      attrs[:commentable_id] = map_id(n["source_commentable_id"])
    end

    if n["subtype"] == "statement" && n["source_statementable_id"]
      attrs[:statementable_type] = n["source_statementable_type"]
      attrs[:statementable_id] = map_id(n["source_statementable_id"])
    end

    note = Note.new(attrs)
    note.save!(validate: false)
    register_id(n["source_id"], note.id)

    preserve_timestamps(note, n)
    preserve_soft_delete(note, n)
  end

  sig { void }
  def import_decisions
    decisions_data = read_json("decisions.json")
    decisions_data.each do |d|
      decision = Decision.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        subtype: d["subtype"],
        question: d["question"],
        description: d["description"],
        options_open: d["options_open"],
        deadline: d["deadline"] ? Time.zone.parse(d["deadline"]) : nil,
        created_by_id: map_id!(d["source_created_by_id"]),
        updated_by_id: map_id(d["source_updated_by_id"]) || map_id!(d["source_created_by_id"]),
        decision_maker_id: map_id(d["source_decision_maker_id"]),
        lottery_beacon_round: d["lottery_beacon_round"],
        lottery_beacon_randomness: d["lottery_beacon_randomness"]
      )
      decision.save!(validate: false)
      register_id(d["source_id"], decision.id)

      preserve_timestamps(decision, d)
      preserve_soft_delete(decision, d)
      preserve_deadline_fired(decision, d)

      # Clear audit_chain_hash — imported chains are historical, not verifiable with new IDs
      decision.update_columns(audit_chain_hash: nil) if d["audit_chain_hash"].present?
    end
    @record_counts["decisions"] = decisions_data.length
  end

  sig { void }
  def import_decision_participants
    data = read_json("decision_participants.json")
    data.each do |p|
      participant = DecisionParticipant.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        decision_id: map_id!(p["source_decision_id"]),
        user_id: map_id!(p["source_user_id"]),
        participant_uid: SecureRandom.uuid,
        vote_receipt_email: p["vote_receipt_email"]
      )
      participant.save!(validate: false)
      register_id(p["source_id"], participant.id)

      preserve_timestamps(participant, p)
    end
    @record_counts["decision_participants"] = data.length
  end

  sig { void }
  def import_options
    data = read_json("options.json")
    data.each do |o|
      option = Option.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        decision_id: map_id!(o["source_decision_id"]),
        decision_participant_id: map_id(o["source_decision_participant_id"]),
        title: o["title"],
        description: o["description"],
        random_id: o["random_id"]
      )
      option.save!(validate: false) # audit-safety-ignore: data import bypasses audit chain intentionally
      register_id(o["source_id"], option.id)

      preserve_timestamps(option, o)
    end
    @record_counts["options"] = data.length
  end

  sig { void }
  def import_votes
    data = read_json("votes.json")
    data.each do |v|
      vote = Vote.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        decision_id: map_id!(v["source_decision_id"]),
        option_id: map_id!(v["source_option_id"]),
        decision_participant_id: map_id!(v["source_decision_participant_id"]),
        accepted: v["accepted"],
        preferred: v["preferred"]
      )
      vote.save!(validate: false) # audit-safety-ignore: data import bypasses audit chain intentionally
      register_id(v["source_id"], vote.id)

      preserve_timestamps(vote, v)
    end
    @record_counts["votes"] = data.length
  end

  sig { void }
  def import_decision_audit_entries
    data = read_json("decision_audit_entries.json")
    data.each do |e|
      # Insert directly to avoid immutability triggers and preserve the original hash chain
      DecisionAuditEntry.insert!({
                                   tenant_id: @tenant.id,
                                   collective_id: @data_import.collective_id,
                                   decision_id: map_id!(e["source_decision_id"]),
                                   sequence_number: e["sequence_number"],
                                   schema_version: e["schema_version"],
                                   action: e["action"],
                                   actor_id: map_id(e["source_actor_id"]),
                                   actor_handle: e["actor_handle"],
                                   option_title: e["option_title"],
                                   accepted: e["accepted"],
                                   preferred: e["preferred"],
                                   metadata: (e["metadata"] || {}).merge("imported" => true),
                                   previous_hash: e["previous_hash"],
                                   entry_hash: e["entry_hash"],
                                   created_at: e["created_at"],
                                 })
    end
    @record_counts["decision_audit_entries"] = data.length
  end

  sig { void }
  def import_commitments
    data = read_json("commitments.json")
    data.each do |c|
      commitment = Commitment.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        subtype: c["subtype"],
        title: c["title"],
        description: c["description"],
        critical_mass: c["critical_mass"],
        limit: c["limit"],
        deadline: c["deadline"] ? Time.zone.parse(c["deadline"]) : nil,
        created_by_id: map_id!(c["source_created_by_id"]),
        updated_by_id: map_id(c["source_updated_by_id"]) || map_id!(c["source_created_by_id"])
      )
      commitment.save!(validate: false)
      register_id(c["source_id"], commitment.id)

      preserve_timestamps(commitment, c)
      preserve_soft_delete(commitment, c)
      preserve_deadline_fired(commitment, c)
    end
    @record_counts["commitments"] = data.length
  end

  sig { void }
  def import_commitment_participants
    data = read_json("commitment_participants.json")
    data.each do |p|
      participant = CommitmentParticipant.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        commitment_id: map_id!(p["source_commitment_id"]),
        user_id: map_id!(p["source_user_id"]),
        participant_uid: SecureRandom.uuid,
        committed_at: p["committed_at"] ? Time.zone.parse(p["committed_at"]) : nil
      )
      participant.save!(validate: false)
      register_id(p["source_id"], participant.id)

      preserve_timestamps(participant, p)
    end
    @record_counts["commitment_participants"] = data.length
  end

  sig { void }
  def import_note_history_events
    data = read_json("note_history_events.json")
    data.each do |e|
      note_id = map_id(e["source_note_id"])
      next unless note_id # Skip if note wasn't imported

      event = NoteHistoryEvent.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        note_id: note_id,
        user_id: map_id(e["source_user_id"]),
        event_type: e["event_type"],
        happened_at: e["happened_at"] ? Time.zone.parse(e["happened_at"]) : nil
      )
      event.save!(validate: false)
      register_id(e["source_id"], event.id)

      preserve_timestamps(event, e)
    end
    @record_counts["note_history_events"] = data.length
  end

  sig { void }
  def import_heartbeats
    data = read_json_optional("heartbeats.json")
    data.each do |h|
      heartbeat = Heartbeat.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        user_id: map_id!(h["source_user_id"]),
        expires_at: h["expires_at"] ? Time.zone.parse(h["expires_at"]) : nil,
        activity_log: h["activity_log"]
      )
      heartbeat.save!(validate: false)
      register_id(h["source_id"], heartbeat.id)

      preserve_timestamps(heartbeat, h)
    end
    @record_counts["heartbeats"] = data.length
  end

  sig { void }
  def import_invites
    data = read_json_optional("invites.json")
    data.each do |i|
      invite = Invite.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        created_by_id: map_id(i["source_created_by_id"]),
        invited_user_id: map_id(i["source_invited_user_id"]),
        code: SecureRandom.hex(8), # Generate new invite code
        expires_at: i["expires_at"] ? Time.zone.parse(i["expires_at"]) : nil
      )
      invite.save!(validate: false)
      register_id(i["source_id"], invite.id)
    end
    @record_counts["invites"] = data.length
  end

  sig { void }
  def import_representation_sessions
    data = read_json_optional("representation_sessions.json")
    data.each do |s|
      session = RepresentationSession.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        representative_user_id: map_id!(s["source_representative_user_id"]),
        began_at: s["began_at"] ? Time.zone.parse(s["began_at"]) : nil,
        ended_at: s["ended_at"] ? Time.zone.parse(s["ended_at"]) : nil,
        confirmed_understanding: s["confirmed_understanding"]
      )
      # trustee_grant_id is not imported (cross-user, not collective-scoped)
      session.save!(validate: false)
      register_id(s["source_id"], session.id)

      preserve_timestamps(session, s)
    end
    @record_counts["representation_sessions"] = data.length
  end

  sig { void }
  def import_representation_session_events
    data = read_json_optional("representation_session_events.json")
    data.each do |e|
      session_id = map_id(e["source_representation_session_id"])
      next unless session_id

      # Handle cross-collective resource references
      resource_id = nil
      resource_collective_id = @data_import.collective_id
      if e["source_resource_collective_id"] == @source_collective_id
        # Same collective — remap
        resource_id = map_id(e["source_resource_id"])
      end
      # If different collective, leave resource_id nil (DeletedRecordProxy pattern)

      event = RepresentationSessionEvent.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        representation_session_id: session_id,
        action_name: e["action_name"],
        resource_type: resource_id ? e["resource_type"] : nil,
        resource_id: resource_id,
        resource_collective_id: resource_collective_id
      )
      event.save!(validate: false)
      register_id(e["source_id"], event.id)

      preserve_timestamps(event, e)
    end
    @record_counts["representation_session_events"] = data.length
  end

  # --- Helpers ---

  sig { params(record: T.untyped, data: T::Hash[String, T.untyped]).void }
  def preserve_timestamps(record, data)
    updates = {}
    updates[:created_at] = Time.zone.parse(data["created_at"]) if data["created_at"]
    updates[:updated_at] = Time.zone.parse(data["updated_at"]) if data["updated_at"]
    record.update_columns(updates) if updates.any?
  end

  sig { params(record: T.untyped, data: T::Hash[String, T.untyped]).void }
  def preserve_deadline_fired(record, data)
    return unless data["deadline_event_fired_at"]

    record.update_columns(deadline_event_fired_at: Time.zone.parse(data["deadline_event_fired_at"]))
  end

  sig { params(record: T.untyped, data: T::Hash[String, T.untyped]).void }
  def preserve_soft_delete(record, data)
    return unless data["deleted_at"]

    updates = { deleted_at: Time.zone.parse(data["deleted_at"]) }
    updates[:deleted_by_id] = map_id(data["source_deleted_by_id"]) if data["source_deleted_by_id"]
    record.update_columns(updates)
  end

  sig { void }
  def import_attachments
    data = read_json_optional("attachments.json")
    data.each do |a|
      attachable_id = map_id(a["source_attachable_id"])
      next unless attachable_id # Skip if parent wasn't imported

      attachment = Attachment.new(
        tenant: @tenant,
        collective_id: @data_import.collective_id,
        attachable_type: a["attachable_type"],
        attachable_id: attachable_id,
        created_by_id: map_id(a["source_created_by_id"]),
        updated_by_id: map_id(a["source_updated_by_id"]),
        name: a["name"],
        content_type: a["content_type"],
        byte_size: a["byte_size"],
      )

      # Attach the binary file if it exists in the ZIP
      if a["filename"] && @zip_data["attachments/#{a["filename"]}"]
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(T.must(@zip_data["attachments/#{a["filename"]}"])),
          filename: a["name"],
          content_type: a["content_type"] || "application/octet-stream",
        )
        attachment.file = blob
      end

      attachment.save!(validate: false)
      register_id(a["source_id"], attachment.id)

      preserve_timestamps(attachment, a)
    end
    @record_counts["attachments"] = data.length
  end

  # --- Text rewriting ---

  # Rewrites internal links, @ mentions, and attachment URLs in all imported text content.
  # Must run after all records are created so the ID map and handle mappings are complete.
  sig { void }
  def rewrite_text_references
    truncated_id_map = build_truncated_id_map
    attachment_id_map = build_attachment_id_map
    handle_map = build_handle_map
    source_manifest = @data_import.source_manifest || {}
    source_hostname = source_manifest["source_instance"] || ""
    source_subdomain = source_manifest["source_subdomain"] || ""
    source_collective_handle = source_manifest.dig("collective", "handle") || ""
    target_collective = Collective.find(T.must(@data_import.collective_id))
    target_collective_handle = target_collective.handle
    target_subdomain = @tenant.subdomain
    target_hostname = ENV.fetch("HOSTNAME", "localhost")

    rewrite_opts = {
      truncated_id_map: truncated_id_map,
      attachment_id_map: attachment_id_map,
      handle_map: handle_map,
      source_hostname: source_hostname,
      source_subdomain: source_subdomain,
      source_collective_handle: source_collective_handle,
      target_hostname: target_hostname,
      target_subdomain: target_subdomain,
      target_collective_handle: T.must(target_collective_handle),
    }

    # Rewrite notes (title and text fields)
    Note.with_deleted.where(collective_id: @data_import.collective_id).find_each do |note|
      rewrite_record_fields(note, [:title, :text], rewrite_opts)
    end

    # Rewrite decisions (question and description fields)
    Decision.with_deleted.where(collective_id: @data_import.collective_id).find_each do |decision|
      rewrite_record_fields(decision, [:question, :description], rewrite_opts)
    end

    # Rewrite commitments (title and description fields)
    Commitment.with_deleted.where(collective_id: @data_import.collective_id).find_each do |commitment|
      rewrite_record_fields(commitment, [:title, :description], rewrite_opts)
    end

    # Rewrite options (title and description fields)
    decision_ids = Decision.with_deleted.where(collective_id: @data_import.collective_id).pluck(:id)
    Option.where(decision_id: decision_ids).find_each do |option|
      rewrite_record_fields(option, [:title, :description], rewrite_opts)
    end

    # Regenerate Link records from the rewritten text.
    # The import skips Link import (they're regenerated from text), and update_columns
    # above bypasses the Linkable after_save callback, so we trigger it explicitly.
    [Note, Decision, Commitment].each do |model|
      scope = model.respond_to?(:with_deleted) ? model.with_deleted : model
      scope.where(collective_id: @data_import.collective_id).find_each do |record|
        record.parse_and_create_link_records! if record.respond_to?(:parse_and_create_link_records!)
      end
    end
    @record_counts["links"] = Link.where(collective_id: @data_import.collective_id).count
  end

  sig { params(record: T.untyped, fields: T::Array[Symbol], opts: T::Hash[Symbol, T.untyped]).void }
  def rewrite_record_fields(record, fields, opts)
    updates = {}
    fields.each do |field|
      old_value = record.send(field)
      next if old_value.blank?

      new_value = rewrite_text(old_value, **T.unsafe(opts))
      updates[field] = new_value if new_value != old_value
    end
    record.update_columns(updates) if updates.any?
  end

  sig { params(
    text: String,
    truncated_id_map: T::Hash[String, String],
    attachment_id_map: T::Hash[String, String],
    handle_map: T::Hash[String, String],
    source_hostname: String,
    source_subdomain: String,
    source_collective_handle: String,
    target_hostname: String,
    target_subdomain: String,
    target_collective_handle: String,
  ).returns(String) }
  def rewrite_text(text, truncated_id_map:, attachment_id_map:, handle_map:, source_hostname:, source_subdomain:, source_collective_handle:, target_hostname:, target_subdomain:, target_collective_handle:)
    result = text

    # Rewrite full URLs: https://subdomain.hostname/collectives/handle/n/truncated_id
    if source_hostname.present? && source_subdomain.present? && source_collective_handle.present?
      full_url_pattern = /https:\/\/#{Regexp.escape(source_subdomain)}\.#{Regexp.escape(source_hostname)}\/(collectives|workspace)\/#{Regexp.escape(source_collective_handle)}\/([ndcr])\/([0-9a-f-]+)(\/\S*)?/
      result = result.gsub(full_url_pattern) do
        scope_prefix = $1 # preserve "collectives" or "workspace"
        type_prefix = $2
        old_id = $3
        suffix = $4 || ""
        new_id = truncated_id_map[old_id] || old_id
        suffix = remap_attachment_ids_in_suffix(suffix, attachment_id_map)
        "https://#{target_subdomain}.#{target_hostname}/#{scope_prefix}/#{target_collective_handle}/#{type_prefix}/#{new_id}#{suffix}"
      end
    end

    # Rewrite markdown path links: [text](/collectives/handle/n/truncated_id...)
    # Also handles image links ![alt](/collectives/...) since they contain ](/...
    if source_collective_handle.present?
      path_pattern = /(\]\()\/(collectives|workspace)\/#{Regexp.escape(source_collective_handle)}\/([ndcr])\/([0-9a-f-]+)(\/[^\)]*)?(\))/
      result = result.gsub(path_pattern) do
        link_open = $1
        scope_prefix = $2 # preserve "collectives" or "workspace"
        type_prefix = $3
        old_id = $4
        suffix = $5 || ""  # e.g., /attachments/uuid
        link_close = $6
        new_id = truncated_id_map[old_id] || old_id
        # Remap attachment UUIDs in the suffix
        suffix = remap_attachment_ids_in_suffix(suffix, attachment_id_map)
        "#{link_open}/#{scope_prefix}/#{target_collective_handle}/#{type_prefix}/#{new_id}#{suffix}#{link_close}"
      end
    end

    # Note: markdown image links ![alt](/path) are already handled by the path pattern above,
    # since they contain ](/path) which matches the same regex.

    # Rewrite @ mentions in a single pass to avoid cascading replacements
    # (e.g., @bob -> @alice then @alice -> @alice-smith would be wrong)
    if handle_map.any?
      escaped_handles = handle_map.keys.sort_by { |h| -h.length }.map { |h| Regexp.escape(h) }
      mention_pattern = /(?<=@)(#{escaped_handles.join("|")})(?![a-zA-Z0-9_-])/
      result = result.gsub(mention_pattern) { |match| handle_map[match] || match }
    end

    result
  end

  # Build a mapping from source truncated_id to new truncated_id.
  # Single forward pass: iterate export data, look up new IDs from @id_map,
  # batch-fetch new truncated_ids from the database.
  sig { returns(T::Hash[String, String]) }
  def build_truncated_id_map
    # Collect source_id -> source_truncated_id from export data
    source_truncated_ids = {} # { source_id => source_truncated_id }
    %w[notes.json decisions.json commitments.json representation_sessions.json].each do |filename|
      read_json_optional(filename).each do |record|
        next unless record["truncated_id"].present?
        source_truncated_ids[record["source_id"]] = record["truncated_id"]
      end
    end

    # Build new_id -> source_truncated_id using @id_map (forward lookup, O(1) per entry)
    new_id_to_source_truncated = {}
    source_truncated_ids.each do |source_id, source_tid|
      new_id = @id_map[source_id]
      next unless new_id
      new_id_to_source_truncated[new_id] = source_tid
    end

    # Batch-fetch new truncated_ids from the database
    map = {}
    new_id_to_source_truncated.keys.each_slice(500) do |batch|
      [Note, Decision, Commitment, RepresentationSession].each do |model|
        scope = T.unsafe(model).respond_to?(:with_deleted) ? T.unsafe(model).with_deleted : model
        scope.where(id: batch).pluck(:id, :truncated_id).each do |new_id, new_tid|
          source_tid = new_id_to_source_truncated[new_id]
          map[source_tid] = new_tid if source_tid
        end
      end
    end
    map
  end

  # Build a mapping from source attachment UUID to new attachment UUID
  sig { returns(T::Hash[String, String]) }
  def build_attachment_id_map
    map = {}
    read_json_optional("attachments.json").each do |a|
      new_id = @id_map[a["source_id"]]
      map[a["source_id"]] = new_id if new_id
    end
    map
  end

  # Remap attachment UUIDs in a URL suffix like /attachments/old-uuid
  sig { params(suffix: String, attachment_id_map: T::Hash[String, String]).returns(String) }
  def remap_attachment_ids_in_suffix(suffix, attachment_id_map)
    return suffix unless suffix.include?("/attachments/")

    suffix.gsub(%r{/attachments/([0-9a-f-]{36})}) do
      old_attachment_id = $1
      new_attachment_id = attachment_id_map[old_attachment_id] || old_attachment_id
      "/attachments/#{new_attachment_id}"
    end
  end

  # Build a mapping from source user handle to target user handle
  sig { returns(T::Hash[String, String]) }
  def build_handle_map
    map = {}
    users_data = read_json("users.json")
    users_data.each do |u|
      source_handle = u["handle"]
      next if source_handle.blank?

      target_user_id = map_id(u["source_id"])
      next unless target_user_id

      target_tenant_user = TenantUser.find_by(tenant_id: @tenant.id, user_id: target_user_id)
      next unless target_tenant_user

      map[source_handle] = target_tenant_user.handle
    end
    map
  end

  # Remove auto-generated note history events from import. The Note model creates
  # a "create" NoteHistoryEvent on after_save, but we import the original history events
  # from the export, so the auto-generated ones would be duplicates.
  sig { void }
  def clear_auto_generated_history_events
    NoteHistoryEvent.where(collective_id: @data_import.collective_id).delete_all
  end

  sig { params(base_handle: String).returns(String) }
  def unique_handle(base_handle)
    handle = base_handle
    suffix = 1
    while Collective.tenant_scoped_only(@tenant.id).exists?(handle: handle)
      handle = "#{base_handle}-imported-#{suffix}"
      suffix += 1
    end
    handle
  end

  sig { params(previous_tenant_id: T.nilable(String), previous_collective_id: T.nilable(String), previous_collective_handle: T.nilable(String)).void }
  def restore_thread_scope(previous_tenant_id, previous_collective_id, previous_collective_handle)
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
