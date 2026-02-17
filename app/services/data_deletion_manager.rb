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
      # Delete all associated data (all within same tenant, cross-collective)
      [
        RepresentationSessionEvent, RepresentationSession,
        Link, NoteHistoryEvent, Note,
        Vote, Option, DecisionParticipant, Decision,
        CommitmentParticipant, Commitment,
        Invite, CollectiveMember
      ].each do |model|
        model.tenant_scoped_only(collective.tenant_id).where(collective_id: collective.id).delete_all
      end
      # Delete proxy user only if it does not have any conflicting associations
      # begin
      #   delete_user!(user: collective.proxy_user, confirmation_token: confirmation_token)
      # rescue ActiveRecord::RecordNotDestroyed
      #   Rails.logger.info "Proxy user for collective '#{collective_name}' (ID: #{collective_id_value}) could not be deleted due to conflicting associations."
      # end
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
    ActiveRecord::Base.transaction do
      # OauthIdentities can be completely deleted (no tenant scope)
      OauthIdentity.where(user_id: user.id).delete_all
      user.email = "#{SecureRandom.hex(10)}@deleted.user"
      user.name = "Deleted User"
      user.image.purge if user.image.attached?
      user.save!
      # API tokens are marked as deleted but not destroyed
      ApiToken.for_user_across_tenants(user).update_all(deleted_at: Time.current)
      User.where(parent_id: user.id).each do |ai_agent| # User has no tenant scope
        # AI agent users are not modified, but their API tokens are marked as deleted
        ApiToken.for_user_across_tenants(ai_agent).update_all(deleted_at: Time.current)
      end
      CollectiveMember.for_user_across_tenants(user).each do |collective_member|
        collective_member_is_sole_admin = collective_member.is_admin? && collective_member.collective.admins.count == 1
        if collective_member_is_sole_admin
          # If the user is the only admin of the collective, we need to assign a new admin
          other_collective_members = collective_member.collective.collective_members.where.not(user_id: user.id).where(archived_at: nil)
          representatives =  other_collective_members.where_has_role('representative')
          new_admin = representatives.first || other_collective_members.first
          if new_admin
            new_admin.add_role!('admin')
          else
            # If there are no other users, ??? Need to handle this case
            # TODO
          end
        end
        collective_member.archived_at = Time.current
        collective_member.save!
      end
      TenantUser.for_user_across_tenants(user).each do |tenant_user|
        tenant_user.update!(
          display_name: "Deleted User",
          handle: "#{SecureRandom.hex(10)}-deleted",
          settings: tenant_user.settings.merge(
            pinned: {},
          ),
          archived_at: Time.current,
        )
      end
    end
    "PII for user '#{user.id}' has been removed and the user has been marked as deleted."
  end

  sig { params(note: Note, confirmation_token: String).returns(String) }
  def delete_note!(note:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    note_title = note.title
    note_id = note.id
    ActiveRecord::Base.transaction do
      # Delete all associated data (always in same collective as parent)
      NoteHistoryEvent.where(note_id: note.id).each do |event|
        event.destroy!
      end
      # Links can be cross-collective (for scenes), so query tenant-wide
      Link.tenant_scoped_only(note.tenant_id).where(from_linkable: note).or(
        Link.tenant_scoped_only(note.tenant_id).where(to_linkable: note)
      ).each do |link|
        link.destroy!
      end
      # Delete the note itself
      note.destroy!
    end
    # Log the deletion
    # Rails.logger.info "Note '#{note_title}' (ID: #{note_id}) has been deleted by user '#{@user.name}' (ID: #{@user.id})."
    # Notify the user about the deletion
    "Note '#{note_title}' (ID: #{note_id}) has been deleted successfully."
  end

  sig { params(decision: Decision, confirmation_token: String).returns(String) }
  def delete_decision!(decision:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    decision_question = decision.question
    decision_id = decision.id
    ActiveRecord::Base.transaction do
      # Delete all associated data (always in same collective as parent)
      Vote.where(decision_id: decision.id).each do |vote|
        vote.destroy!
      end
      Option.where(decision_id: decision.id).each do |option|
        option.destroy!
      end
      DecisionParticipant.where(decision_id: decision.id).each do |participant|
        participant.destroy!
      end
      # Links can be cross-collective (for scenes), so query tenant-wide
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
      # Links can be cross-collective (for scenes), so query tenant-wide
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