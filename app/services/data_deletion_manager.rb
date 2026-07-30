# typed: true

# DataDeletionManager handles destructive data operations for admin use.
#
# IMPORTANT: This class uses safe unscoped wrapper methods to delete data across
# all tenants/collectives. It is designed to be used only from Rails console
# with explicit confirmation tokens.
#
class DataDeletionManager
  extend T::Sig

  attr_reader :confirmation_token

  sig { params(user: User).void }
  def initialize(user:)
    @user = user
    # The validation confirmation token is a guard against accidental deletion.
    # Clients of this class must inspect the code to understand how it works
    # before calling the deletion methods.
    @confirmation_token = SecureRandom.hex(10)
  end

  sig { params(token: String, message: T.nilable(String)).void }
  def validate_confirmation_token!(token, message: nil)
    message = "Invalid confirmation token. #{message}"
    raise message unless token == @confirmation_token
  end

  sig { params(collective: Collective, confirmation_token: String).returns(String) }
  def delete_collective!(collective:, confirmation_token:)
    validate_confirmation_token!(confirmation_token, message: "delete_collective! will delete all associated Notes, Decisions, Commitments, RepresentationSessions, TrusteeUsers, and any other associated data.")
    # Ensure the collective exists
    collective_name = collective.name
    collective_id_value = collective.id
    ActiveRecord::Base.transaction do
      # Events have notifications and webhook_deliveries with DB-enforced FKs;
      # clear those (and notification_recipients) before deleting events themselves.
      event_ids = Event.tenant_scoped_only(collective.tenant_id).where(collective_id: collective.id).pluck(:id)
      if event_ids.any?
        notification_ids = Notification.where(event_id: event_ids).pluck(:id)
        NotificationRecipient.where(notification_id: notification_ids).delete_all if notification_ids.any?
        Notification.where(event_id: event_ids).delete_all
        WebhookDelivery.where(event_id: event_ids).delete_all
      end
      # Delete all associated data (all within same tenant, cross-collective)
      [
        Event,
        RepresentationSessionEvent, RepresentationSession,
        Link, NoteHistoryEvent, Note,
        DecisionAuditEntry, Vote, Option, DecisionParticipant, Decision,
        CommitmentParticipant, Commitment,
        Invite, CollectiveMember
      ].each do |model|
        model.tenant_scoped_only(collective.tenant_id).where(collective_id: collective.id).delete_all
      end
      # Delete the collective itself
      collective.destroy!
    end
    # Log the deletion
    # Rails.logger.info "Collective '#{collective_name}' (ID: #{collective_id_value}) has been deleted by user '#{@user.name}' (ID: #{@user.id})."
    # Notify the user about the deletion
    "Collective '#{collective_name}' (ID: #{collective_id_value}) has been deleted successfully."
  end

  sig { params(user: User, confirmation_token: String, force_delete: T::Boolean).returns(String) }
  def delete_user!(user:, confirmation_token:, force_delete: false)
    validate_confirmation_token!(confirmation_token)
    if force_delete
      raise NotImplementedError, "full deletion of users is not implemented yet"
    end
    # Deletion is blocked while the user is the only active admin of a
    # collective that still has other active members — the admin role must be
    # transferred first (the members page, update_member_roles). Collectives
    # where the user is the only remaining member are archived during deletion
    # instead.
    blocking_handles = AccountClosureService.sole_admin_blocking_handles(user)
    if blocking_handles.any?
      raise "Cannot delete user: they are the sole admin of collectives with other members: " \
            "#{blocking_handles.join(', ')}. Transfer the admin role first (update_member_roles)."
    end
    # Billing cleanup happens before any local mutation: if the Stripe call
    # fails, deletion aborts with nothing scrubbed. Remaining prepaid balance
    # is forfeited with the vendor-side customer object.
    stripe_customer = StripeCustomer.find_by(billable: user)
    StripeService.close_customer!(stripe_customer) if stripe_customer
    ActiveRecord::Base.transaction do
      # OauthIdentities and OmniAuthIdentity can be completely deleted (no tenant scope)
      OauthIdentity.where(user_id: user.id).delete_all
      user.omni_auth_identity&.destroy!
      user.email = "#{SecureRandom.hex(10)}@deleted.user"
      user.name = "Deleted User"
      user.image.purge if user.image.attached?
      user.save!
      # Terminate all access: sessions, refresh tokens, push subscriptions, and
      # API tokens (the user's and their AI agents' — soft-deleted, not destroyed).
      user.revoke_all_sessions!
      # Trustee authorizations in both directions — nobody may act for this user
      # again, and this user's trustee relationships must not survive them.
      TrusteeGrant.for_user_across_tenants(user)
        .where(revoked_at: nil, declined_at: nil)
        .update_all(revoked_at: Time.current)
      # User-owned automation rules (including the notification forwarder) must
      # stop firing — a forwarder would keep sending the user's notification
      # content to an external URL.
      AutomationRule.for_user_across_tenants(user).where(deleted_at: nil).find_each do |rule|
        rule.soft_delete!(by: user)
      end
      # The user's data exports contain exactly the data being scrubbed.
      DataExport.for_user_across_tenants(user).find_each do |export|
        export.file.purge if export.file.attached?
        export.destroy!
      end
      # Decision audit chains: null the identity columns (the chain hashes are
      # untouched, so entries verify as scrubbed rather than tampered).
      DecisionAuditEntry.scrub_identity_for!(user)
      # Child AI agents cannot act without a principal: archive them, revoke
      # their trustee authorizations, and stop their automation rules. Their
      # content survives, like the principal's.
      User.where(parent_id: user.id).find_each do |ai_agent| # User has no tenant scope
        TrusteeGrant.for_user_across_tenants(ai_agent)
          .where(revoked_at: nil, declined_at: nil)
          .update_all(revoked_at: Time.current)
        AutomationRule.for_user_across_tenants(ai_agent).where(deleted_at: nil).find_each do |rule|
          rule.soft_delete!(by: user)
        end
        TenantUser.for_user_across_tenants(ai_agent)
          .where(archived_at: nil)
          .update_all(archived_at: Time.current)
      end
      CollectiveMember.for_user_across_tenants(user).each do |collective_member|
        if collective_member.archived_at.nil? && collective_member.is_admin?
          collective = Collective.tenant_scoped_only(collective_member.tenant_id)
            .find_by(id: collective_member.collective_id)
          if collective && collective.archived_at.nil?
            active_admins = CollectiveMember.tenant_scoped_only(collective_member.tenant_id)
              .where(collective_id: collective.id, archived_at: nil)
            if T.unsafe(active_admins).where_has_role("admin").count == 1
              # The precheck above guarantees no other active members remain —
              # archive the empty collective and stop its automations.
              collective.update!(archived_at: Time.current, archived_by_id: user.id)
              AutomationRule.tenant_scoped_only(collective.tenant_id)
                .where(collective_id: collective.id, enabled: true)
                .update_all(enabled: false)
            end
          end
        end
        collective_member.archived_at = Time.current
        collective_member.save!
      end
      TenantUser.for_user_across_tenants(user).each do |tenant_user|
        tenant_user.update!(
          display_name: "Deleted User",
          handle: "#{SecureRandom.hex(10)}-deleted",
          bio: nil,
          location: nil,
          website: nil,
          settings: tenant_user.settings.merge(
            "pinned" => {},
          ),
          archived_at: Time.current,
        )
      end
      # Mark the irreversible phase complete so the closure scrub job never
      # re-selects this account.
      user.update!(scrubbed_at: Time.current) if user.scrubbed_at.nil?
    end
    "PII for user '#{user.id}' has been removed and the user has been marked as deleted."
  end

  sig { params(note: Note, confirmation_token: String).returns(String) }
  def delete_note!(note:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    note_title = note.raw_title || note.title
    note_id = note.id
    self.class.send(:cascade_delete_note, note)
    "Note '#{note_title}' (ID: #{note_id}) has been deleted successfully."
  end

  # System-job entry point invoked by HardDeleteExpiredRecordsJob once a soft-
  # deleted note's grace period has expired. Tombstones the note: nulls
  # the authored content (title/text/table_data), purges attachments, destroys
  # Link records, and sets tombstoned_at. The row stays in the DB so any
  # external references (B's comments, NoteHistoryEvents) continue to resolve
  # to a real row that renders as [deleted]. Full hard-delete remains available
  # via the console admin delete_note! method.
  #
  # Wrapped in a transaction with a row lock so concurrent updates are
  # serialized. Bypasses the user+token guard; the naming and class-method
  # placement signal it's intended for SystemJob callers only.
  sig { params(note: Note).void }
  def self.system_tombstone_note!(note:)
    ActiveRecord::Base.transaction do
      note.lock!
      note.attachments.destroy_all if note.respond_to?(:attachments) && note.attachments.exists?
      Link.tenant_scoped_only(note.tenant_id).where(from_linkable: note).or(
        Link.tenant_scoped_only(note.tenant_id).where(to_linkable: note)
      ).each(&:destroy!)
      note.update_columns(
        title: nil,
        text: nil,
        table_data: nil,
        tombstoned_at: Time.current,
      )
    end
  end

  sig { params(note: Note).void }
  private_class_method def self.cascade_delete_note(note)
    ActiveRecord::Base.transaction do
      NoteHistoryEvent.where(note_id: note.id).each(&:destroy!)
      Link.tenant_scoped_only(note.tenant_id).where(from_linkable: note).or(
        Link.tenant_scoped_only(note.tenant_id).where(to_linkable: note)
      ).each(&:destroy!)
      note.destroy!
    end
  end

  sig { params(decision: Decision, confirmation_token: String).returns(String) }
  def delete_decision!(decision:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    decision_question = decision.question
    decision_id = decision.id
    ActiveRecord::Base.transaction do
      # Delete all associated data (always in same collective as parent)
      DecisionAuditEntry.where(decision_id: decision.id).delete_all
      Vote.where(decision_id: decision.id).delete_all
      Option.where(decision_id: decision.id).each do |option|
        option.destroy! # audit-safety-ignore: data deletion bypasses audit chain intentionally
      end
      DecisionParticipant.where(decision_id: decision.id).each do |participant|
        participant.destroy!
      end
      # Links can be cross-collective, so query tenant-wide
      Link.tenant_scoped_only(decision.tenant_id).where(from_linkable: decision).or(
        Link.tenant_scoped_only(decision.tenant_id).where(to_linkable: decision)
      ).each do |link|
        link.destroy!
      end
      # Delete the decision itself
      decision.destroy!
    end
    # Log the deletion
    # Rails.logger.info "Decision '#{decision_question}' (ID: #{decision_id}) has been deleted by user '#{@user.name}' (ID: #{@user.id})."
    # Notify the user about the deletion
    "Decision '#{decision_question}' (ID: #{decision_id}) has been deleted successfully."
  end

  sig { params(commitment: Commitment, confirmation_token: String).returns(String) }
  def delete_commitment!(commitment:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    commitment_title = commitment.title
    commitment_id = commitment.id
    ActiveRecord::Base.transaction do
      # Delete all associated data (always in same collective as parent)
      CommitmentParticipant.where(commitment_id: commitment.id).each do |participant|
        participant.destroy!
      end
      # Links can be cross-collective, so query tenant-wide
      Link.tenant_scoped_only(commitment.tenant_id).where(from_linkable: commitment).or(
        Link.tenant_scoped_only(commitment.tenant_id).where(to_linkable: commitment)
      ).each do |link|
        link.destroy!
      end
      # Delete the commitment itself
      commitment.destroy!
    end
    # Log the deletion
    # Rails.logger.info "Commitment '#{commitment_title}' (ID: #{commitment_id}) has been deleted by user '#{@user.name}' (ID: #{@user.id})."
    # Notify the user about the deletion
    "Commitment '#{commitment_title}' (ID: #{commitment_id}) has been deleted successfully."
  end

  sig { params(representation_session: RepresentationSession, confirmation_token: String).returns(T.noreturn) }
  def delete_representation_session!(representation_session:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    # Delete all associated data
    raise NotImplementedError, "delete_representation_session! is not implemented yet"
  end

end