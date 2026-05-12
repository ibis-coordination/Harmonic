# typed: true

require "zip"

# Per-user data export with a recursive nested structure.
#
# The export is rooted at the parent user's data. Inside, an `ai_agents/`
# directory contains a subdirectory per AI agent child, each of which is
# a fully self-contained export of that agent's data with the same file
# layout (same JSON files, its own manifest). An agent's directory is
# tarball-able and would be a valid standalone export on its own.
#
# Each "view" (the parent at top level, each agent under ai_agents/) is
# scoped to one user. Records that span two subjects (e.g., a TrusteeGrant
# between the parent and one of their agents) appear in BOTH directories
# — both perspectives are accurate and each view stays self-contained.
#
# Scope rule per record type: a record belongs to the view of the user
# who acted on / created it. Notes by created_by_id. Audit entries by
# actor_id. Trustee grants by either party. Links by either endpoint.
# Etc.
#
# See `.claude/plans/per-user-data-export.md` for the full design.
class UserDataExportService
  extend T::Sig

  # A "view" is one user's slice of the export: their user record, their
  # content, their actions, written to one directory. The export contains
  # one view per (human + each AI agent child).
  class View
    extend T::Sig

    sig { returns(User) }
    attr_reader :user

    sig { returns(String) }
    attr_reader :output_dir

    sig { returns(T::Hash[String, Integer]) }
    attr_accessor :record_counts

    sig { returns(T::Hash[String, String]) }
    attr_accessor :checksums

    sig { params(user: User, output_dir: String).void }
    def initialize(user:, output_dir:)
      @user = user
      @output_dir = output_dir
      @record_counts = {}
      @checksums = {}
    end

    sig { returns(String) }
    def user_id
      @user.id
    end
  end

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

    @flat_record_counts = T.let({}, T::Hash[String, Integer])
  end

  sig { void }
  def perform!
    @data_export.update!(status: "processing", started_at: Time.current)

    with_scoped_context do
      Dir.mktmpdir("harmonic-user-export") do |tmpdir|
        # Top-level view: the human user's data.
        top_view = View.new(user: @user, output_dir: tmpdir)
        gather_view(top_view)
        accumulate_counts(top_view.record_counts)

        # Nested views: one per AI agent child that lives in THIS tenant.
        # The User table is shared across tenants — agent membership in
        # a tenant is established via a TenantUser row. Without scoping
        # by that, agents created for the parent in OTHER tenants would
        # leak into this export as empty subdirectories, revealing their
        # existence cross-tenant.
        #
        # Directory name is the agent's handle in this tenant (e.g.
        # `ai_agents/research-bot/`). Handles are `name.parameterize`-
        # derived (lowercase + hyphens, no slashes) so they're
        # filesystem-safe.
        tenant_user_handles = TenantUser.where(tenant_id: @tenant.id)
                                        .pluck(:user_id, :handle)
                                        .to_h
        User.where(parent_id: @user.id, id: tenant_user_handles.keys).find_each do |agent|
          subdir_name = tenant_user_handles[agent.id].presence || agent.id
          agent_dir = File.join(tmpdir, "ai_agents", subdir_name)
          FileUtils.mkdir_p(agent_dir)
          agent_view = View.new(user: agent, output_dir: agent_dir)
          gather_view(agent_view)
          accumulate_counts(agent_view.record_counts)
        end

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
      record_counts: @flat_record_counts,
    )
  rescue StandardError => e
    @data_export.update_columns(status: "failed", error_message: e.message, updated_at: Time.current)
    raise
  end

  private

  # The `data_export.record_counts` DB field stays as a flat
  # `{type => total_count}` map summed across all views. Mailer/UI
  # surfaces consume this shape; the per-view breakdown lives in each
  # view's own manifest.json inside the ZIP.
  sig { params(view_counts: T::Hash[String, Integer]).void }
  def accumulate_counts(view_counts)
    view_counts.each { |type, n| @flat_record_counts[type] = (@flat_record_counts[type] || 0) + n }
  end

  sig { params(view: View).void }
  def gather_view(view)
    gather_notes(view)
    gather_decisions(view)
    gather_options(view)
    gather_commitments(view)
    gather_decision_participants(view)
    gather_votes(view)
    gather_decision_audit_entries(view)
    gather_commitment_participants(view)
    gather_note_history_events(view)
    gather_invites(view)
    gather_trustee_grants(view)
    gather_representation_sessions(view)
    gather_representation_session_events(view)
    gather_links(view)
    gather_users(view)
    gather_tenant_users(view)
    gather_collective_members(view)
    gather_oauth_identities(view)
    gather_omni_auth_identities(view)
    gather_attachments(view)
    write_manifest(view)
  end

  sig { params(view: View).void }
  def gather_notes(view)
    notes = Note.where(collective_id: @collective.id, created_by_id: view.user_id)
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
    write_json(view, "notes.json", data)
    view.record_counts["notes"] = data.length
  end

  sig { params(view: View).void }
  def gather_decisions(view)
    decisions = Decision.where(collective_id: @collective.id, created_by_id: view.user_id)
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
    write_json(view, "decisions.json", data)
    view.record_counts["decisions"] = data.length
  end

  # An Option is "authored by" the user who created its decision_participant.
  # Option doesn't have a direct created_by_id column — authorship flows
  # through the participant.
  sig { params(view: View).void }
  def gather_options(view)
    participant_ids = DecisionParticipant.where(user_id: view.user_id).pluck(:id)
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
    write_json(view, "options.json", data)
    view.record_counts["options"] = data.length
  end

  sig { params(view: View).void }
  def gather_commitments(view)
    commitments = Commitment.where(collective_id: @collective.id, created_by_id: view.user_id)
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
    write_json(view, "commitments.json", data)
    view.record_counts["commitments"] = data.length
  end

  # Participation records: each carries a denormalized label snapshot
  # (decision_question / option_title / commitment_title) so the archive is
  # legible without including the parent records it points at. The snapshot
  # reflects the current label at export time.
  #
  # The explicit `collective_id: @collective.id` filter is defense-in-depth.
  # The default scope inside `with_scoped_context` would filter anyway, but
  # callers that bypass that context would otherwise leak participations
  # from other collectives in the same tenant.
  sig { params(view: View).void }
  def gather_decision_participants(view)
    participants = DecisionParticipant
                     .where(collective_id: @collective.id, user_id: view.user_id)
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
    write_json(view, "decision_participants.json", data)
    view.record_counts["decision_participants"] = data.length
  end

  sig { params(view: View).void }
  def gather_votes(view)
    participant_ids = DecisionParticipant
                        .where(collective_id: @collective.id, user_id: view.user_id)
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
    write_json(view, "votes.json", data)
    view.record_counts["votes"] = data.length
  end

  sig { params(view: View).void }
  def gather_commitment_participants(view)
    participants = CommitmentParticipant
                     .where(collective_id: @collective.id, user_id: view.user_id)
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
    write_json(view, "commitment_participants.json", data)
    view.record_counts["commitment_participants"] = data.length
  end

  # Audit entries are receipts of the view-user's own actions, NOT a
  # verifiable chain (surrounding entries belong to the collective). The
  # user can verify any individual entry via the public receipt URL.
  sig { params(view: View).void }
  def gather_decision_audit_entries(view)
    entries = DecisionAuditEntry.where(collective_id: @collective.id, actor_id: view.user_id)
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
    write_json(view, "decision_audit_entries.json", data)
    view.record_counts["decision_audit_entries"] = data.length
  end

  # The view-user's actions on notes — read confirmations, reminder
  # acknowledgments, edits — regardless of who authored the parent note.
  sig { params(view: View).void }
  def gather_note_history_events(view)
    events = NoteHistoryEvent
               .where(collective_id: @collective.id, user_id: view.user_id)
               .includes(:note)
    data = events.map do |e|
      note = e.note
      {
        "source_id" => e.id,
        "source_note_id" => e.note_id,
        "source_user_id" => e.user_id,
        "event_type" => e.event_type,
        "note_title" => note&.title,
        "happened_at" => e.happened_at&.iso8601,
        "created_at" => e.created_at.iso8601,
        "updated_at" => e.updated_at.iso8601,
      }
    end
    write_json(view, "note_history_events.json", data)
    view.record_counts["note_history_events"] = data.length
  end

  # Invites the view-user sent. `invited_user_id` is a FK to another user
  # (opaque UUID, no PII denormalized onto the row).
  sig { params(view: View).void }
  def gather_invites(view)
    invites = Invite.where(collective_id: @collective.id, created_by_id: view.user_id)
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
    write_json(view, "invites.json", data)
    view.record_counts["invites"] = data.length
  end

  # Trustee grants where the view-user is either party. Grants between
  # the parent and an AI agent (in either direction) appear in BOTH the
  # parent's and the agent's directories — each view stays self-contained.
  #
  # Note: TrusteeGrant is tenant-scoped but not collective-scoped.
  sig { params(view: View).void }
  def gather_trustee_grants(view)
    grants = TrusteeGrant.where(tenant_id: @tenant.id).where(
      "granting_user_id = :id OR trustee_user_id = :id", id: view.user_id,
    )
    data = grants.map do |g|
      {
        "source_id" => g.id,
        "truncated_id" => g.truncated_id,
        "source_granting_user_id" => g.granting_user_id,
        "source_trustee_user_id" => g.trustee_user_id,
        "description" => g.description,
        "permissions" => g.permissions,
        "collective_scope" => g.collective_scope,
        "expires_at" => g.expires_at&.iso8601,
        "accepted_at" => g.accepted_at&.iso8601,
        "declined_at" => g.declined_at&.iso8601,
        "revoked_at" => g.revoked_at&.iso8601,
        "created_at" => g.created_at.iso8601,
        "updated_at" => g.updated_at.iso8601,
      }
    end
    write_json(view, "trustee_grants.json", data)
    view.record_counts["trustee_grants"] = data.length
  end

  # User-to-user representation sessions where the view-user was the
  # representative. The main collective has no representatives, so only
  # collective_id IS NULL (trustee-grant-driven) sessions appear.
  sig { params(view: View).void }
  def gather_representation_sessions(view)
    sessions = RepresentationSession.where(
      collective_id: nil, representative_user_id: view.user_id,
    )
    data = sessions.map do |s|
      {
        "source_id" => s.id,
        "source_representative_user_id" => s.representative_user_id,
        "began_at" => s.began_at.iso8601,
        "ended_at" => s.ended_at&.iso8601,
        "confirmed_understanding" => s.confirmed_understanding,
        "source_trustee_grant_id" => s.trustee_grant_id,
        "created_at" => s.created_at.iso8601,
        "updated_at" => s.updated_at.iso8601,
      }
    end
    write_json(view, "representation_sessions.json", data)
    view.record_counts["representation_sessions"] = data.length
  end

  sig { params(view: View).void }
  def gather_representation_session_events(view)
    session_ids = RepresentationSession
                    .where(collective_id: nil, representative_user_id: view.user_id)
                    .pluck(:id)
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
        "request_id" => e.request_id,
        "created_at" => e.created_at.iso8601,
        "updated_at" => e.updated_at.iso8601,
      }
    end
    write_json(view, "representation_session_events.json", data)
    view.record_counts["representation_session_events"] = data.length
  end

  # Links where either endpoint is content owned by the view-user. Links
  # spanning the parent's content and an agent's content appear in BOTH
  # views — each is self-contained.
  sig { params(view: View).void }
  def gather_links(view)
    owned_note_ids = Note.where(collective_id: @collective.id, created_by_id: view.user_id).pluck(:id)
    owned_decision_ids = Decision.where(collective_id: @collective.id, created_by_id: view.user_id).pluck(:id)
    owned_commitment_ids = Commitment.where(collective_id: @collective.id, created_by_id: view.user_id).pluck(:id)

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
    write_json(view, "links.json", data)
    view.record_counts["links"] = data.length
  end

  # Allowlists for JSONB columns. Open-ended jsonb is dangerous in an
  # export because a new sub-key (e.g. a future cached API key) would
  # silently start leaking. Each allowlist names the keys we deliberately
  # export; everything else is dropped.
  USER_AGENT_CONFIGURATION_KEYS = %w[mode model capabilities identity_prompt].freeze
  TENANT_USER_SETTINGS_KEYS = %w[pinned roles notification_preferences].freeze
  COLLECTIVE_MEMBER_SETTINGS_KEYS = %w[roles].freeze

  sig { params(jsonb: T.nilable(T::Hash[String, T.untyped]), allowed: T::Array[String]).returns(T::Hash[String, T.untyped]) }
  def slice_jsonb(jsonb, allowed)
    return {} if jsonb.nil?

    allowed.each_with_object({}) { |key, acc| acc[key] = jsonb[key] if jsonb.key?(key) }
  end

  # Account-level data for the view-user only. Credentials (password
  # digests, OTP secrets, OAuth tokens) are never exported.
  sig { params(view: View).void }
  def gather_users(view)
    u = view.user
    data = [{
      "source_id" => u.id,
      "email" => u.email,
      "name" => u.name,
      "user_type" => u.user_type,
      "source_parent_id" => u.parent_id,
      "picture_url" => u.picture_url,
      "image_url" => u.image_url,
      "agent_configuration" => slice_jsonb(u.agent_configuration, USER_AGENT_CONFIGURATION_KEYS),
      "created_at" => u.created_at.iso8601,
      "updated_at" => u.updated_at.iso8601,
    }]
    write_json(view, "users.json", data)
    view.record_counts["users"] = data.length
  end

  sig { params(view: View).void }
  def gather_tenant_users(view)
    rows = TenantUser.where(tenant_id: @tenant.id, user_id: view.user_id)
    data = rows.map do |t|
      {
        "source_id" => t.id,
        "source_user_id" => t.user_id,
        "handle" => t.handle,
        "display_name" => t.display_name,
        "settings" => slice_jsonb(t.settings, TENANT_USER_SETTINGS_KEYS),
        "archived_at" => t.archived_at&.iso8601,
        "created_at" => t.created_at.iso8601,
        "updated_at" => t.updated_at.iso8601,
      }
    end
    write_json(view, "tenant_users.json", data)
    view.record_counts["tenant_users"] = data.length
  end

  sig { params(view: View).void }
  def gather_collective_members(view)
    rows = CollectiveMember.where(collective_id: @collective.id, user_id: view.user_id)
    data = rows.map do |m|
      {
        "source_id" => m.id,
        "source_user_id" => m.user_id,
        "settings" => slice_jsonb(m.settings, COLLECTIVE_MEMBER_SETTINGS_KEYS),
        "roles" => m.roles,
        "archived_at" => m.archived_at&.iso8601,
        "created_at" => m.created_at.iso8601,
        "updated_at" => m.updated_at.iso8601,
      }
    end
    write_json(view, "collective_members.json", data)
    view.record_counts["collective_members"] = data.length
  end

  # OAuth provider linkages. `auth_data` (carries access/refresh tokens)
  # is NEVER exported. AI agents typically have no OauthIdentity rows.
  sig { params(view: View).void }
  def gather_oauth_identities(view)
    rows = OauthIdentity.where(user_id: view.user_id)
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
    write_json(view, "oauth_identities.json", data)
    view.record_counts["oauth_identities"] = data.length
  end

  # Email/password identity. Credential fields (password_digest,
  # otp_secret, otp_recovery_codes, reset_password_token) are NEVER
  # exported. AI agents have no OmniAuthIdentity rows.
  sig { params(view: View).void }
  def gather_omni_auth_identities(view)
    rows = OmniAuthIdentity.where(user_id: view.user_id)
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
    write_json(view, "omni_auth_identities.json", data)
    view.record_counts["omni_auth_identities"] = data.length
  end

  # Attachments created by the view-user. Binary content is written under
  # the view's own attachments/ directory.
  sig { params(view: View).void }
  def gather_attachments(view)
    attachments = Attachment.where(collective_id: @collective.id, created_by_id: view.user_id)
    attachments_dir = File.join(view.output_dir, "attachments")
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
    write_json(view, "attachments.json", data)
    view.record_counts["attachments"] = data.length
  end

  # Each view's manifest describes the view's own user, record counts,
  # and checksums. An AI agent's manifest stands on its own — the agent's
  # subdirectory is a complete, valid export when read in isolation.
  sig { params(view: View).void }
  def write_manifest(view)
    manifest = {
      "format_version" => "1.0",
      "export_type" => "user",
      "app_version" => Rails.root.join("VERSION").read.strip,
      "exported_at" => Time.current.iso8601,
      "source_instance" => ENV.fetch("HOSTNAME", "unknown"),
      "source_subdomain" => @tenant.subdomain,
      "subject" => {
        "user_id" => view.user_id,
        "user_type" => view.user.user_type,
        "source_parent_id" => view.user.parent_id,
        "collective_id" => @collective.id,
      },
      "record_counts" => view.record_counts,
      "checksums" => view.checksums,
    }
    write_json(view, "manifest.json", manifest)
  end

  sig { params(view: View, filename: String, data: T.untyped).void }
  def write_json(view, filename, data)
    path = File.join(view.output_dir, filename)
    json = JSON.pretty_generate(data)
    File.write(path, json)
    view.checksums[filename] = "sha256:#{Digest::SHA256.hexdigest(json)}"
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
