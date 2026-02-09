# typed: true

# DataDeletionManager handles destructive data operations for admin use.
#
# IMPORTANT: This class uses .unscoped intentionally to delete data across
# all tenants/superagents. It is designed to be used only from Rails console
# with explicit confirmation tokens. All .unscoped calls here are marked as
# unscoped-allowed since this is a privileged admin operation.
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

  sig { params(superagent: Superagent, confirmation_token: String).returns(String) }
  def delete_superagent!(superagent:, confirmation_token:)
    validate_confirmation_token!(confirmation_token, message: "delete_superagent! will delete all associated Notes, Decisions, Commitments, RepresentationSessions, TrusteeUsers, and any other associated data.")
    # Ensure the superagent exists
    superagent_name = superagent.name
    superagent_id_value = superagent.id
    ActiveRecord::Base.transaction do
      # Delete all associated data
      [
        RepresentationSessionEvent, RepresentationSession,
        Link, NoteHistoryEvent, Note,
        Vote, Option, DecisionParticipant, Decision,
        CommitmentParticipant, Commitment,
        Invite, SuperagentMember
      ].each do |model|
        model.unscoped.where(superagent_id: superagent.id).delete_all # unscoped-allowed
      end
      # Delete trustee user only if it does not have any conflicting associations
      # begin
      #   delete_user!(user: superagent.trustee_user, confirmation_token: confirmation_token)
      # rescue ActiveRecord::RecordNotDestroyed
      #   Rails.logger.info "Trustee user for superagent '#{superagent_name}' (ID: #{superagent_id_value}) could not be deleted due to conflicting associations."
      # end
      # Delete the superagent itself
      superagent.destroy!
    end
    # Log the deletion
    # Rails.logger.info "Superagent '#{superagent_name}' (ID: #{superagent_id_value}) has been deleted by user '#{@user.name}' (ID: #{@user.id})."
    # Notify the user about the deletion
    "Superagent '#{superagent_name}' (ID: #{superagent_id_value}) has been deleted successfully."
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
      ApiToken.unscoped.where(user_id: user.id).update_all(deleted_at: Time.current) # unscoped-allowed
      User.where(parent_id: user.id).each do |subagent| # User has no tenant scope
        # Subagent users are not modified, but their API tokens are marked as deleted
        ApiToken.unscoped.where(user_id: subagent.id).update_all(deleted_at: Time.current) # unscoped-allowed
      end
      SuperagentMember.unscoped.where(user_id: user.id).each do |superagent_member| # unscoped-allowed
        superagent_member_is_sole_admin = superagent_member.is_admin? && superagent_member.superagent.admins.count == 1
        if superagent_member_is_sole_admin
          # If the user is the only admin of the superagent, we need to assign a new admin
          other_superagent_members = superagent_member.superagent.superagent_members.where.not(user_id: user.id).where(archived_at: nil)
          representatives =  other_superagent_members.where_has_role('representative')
          new_admin = representatives.first || other_superagent_members.first
          if new_admin
            new_admin.add_role!('admin')
          else
            # If there are no other users, ??? Need to handle this case
            # TODO
          end
        end
        superagent_member.archived_at = Time.current
        superagent_member.save!
      end
      TenantUser.unscoped.where(user_id: user.id).each do |tenant_user| # unscoped-allowed
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
      # Delete all associated data
      NoteHistoryEvent.unscoped.where(note_id: note.id).each do |event| # unscoped-allowed
        event.destroy!
      end
      # Link where the note is the from_linkable or the to_linkable
      Link.unscoped.where(from_linkable: note).or(Link.unscoped.where(to_linkable: note)).each do |link| # unscoped-allowed
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
      # Delete all associated data
      Vote.unscoped.where(decision_id: decision.id).each do |vote| # unscoped-allowed
        vote.destroy!
      end
      Option.unscoped.where(decision_id: decision.id).each do |option| # unscoped-allowed
        option.destroy!
      end
      DecisionParticipant.unscoped.where(decision_id: decision.id).each do |participant| # unscoped-allowed
        participant.destroy!
      end
      Link.unscoped.where(from_linkable: decision).or(Link.unscoped.where(to_linkable: decision)).each do |link| # unscoped-allowed
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
      # Delete all associated data
      CommitmentParticipant.unscoped.where(commitment_id: commitment.id).each do |participant| # unscoped-allowed
        participant.destroy!
      end
      Link.unscoped.where(from_linkable: commitment).or(Link.unscoped.where(to_linkable: commitment)).each do |link| # unscoped-allowed
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