class DataDeletionManager
  attr_reader :confirmation_token

  def initialize(user:)
    @user = user
    # The validation confirmation token is a guard against accidental deletion.
    # Clients of this class must inspect the code to understand how it works
    # before calling the deletion methods.
    @confirmation_token = SecureRandom.hex(10)
  end

  def validate_confirmation_token!(token, message: nil)
    message = "Invalid confirmation token. #{message}"
    raise message unless token == @confirmation_token
  end

  def delete_studio!(studio:, confirmation_token:)
    validate_confirmation_token!(confirmation_token, message: "delete_studio! will delete all associated Notes, Decisions, Commitments, RepresentationSessions, TrusteeUsers, and any other associated data.")
    # Ensure the studio exists
    studio_name = studio.name
    studio_id = studio.id
    raise "studio.id returned nil" if studio_id.nil?
    ActiveRecord::Base.transaction do
      # Delete all associated data
      [
        RepresentationSessionAssociation, RepresentationSession,
        Link, NoteHistoryEvent, Note,
        Approval, Option, DecisionParticipant, Decision,
        CommitmentParticipant, Commitment,
        StudioInvite, StudioUser
      ].each do |model|
        model.unscoped.where(studio_id: studio.id).delete_all
      end
      # Delete trustee user only if it does not have any conflicting associations
      # begin
      #   delete_user!(user: studio.trustee_user, confirmation_token: confirmation_token)
      # rescue ActiveRecord::RecordNotDestroyed
      #   Rails.logger.info "Trustee user for studio '#{studio_name}' (ID: #{studio_id}) could not be deleted due to conflicting associations."
      # end
      # Delete the studio itself
      studio.destroy!
    end
    # Log the deletion
    # Rails.logger.info "Studio '#{studio_name}' (ID: #{studio_id}) has been deleted by user '#{@user.name}' (ID: #{@user.id})."
    # Notify the user about the deletion
    "Studio '#{studio_name}' (ID: #{studio_id}) has been deleted successfully."
  end

  def delete_user!(user:, confirmation_token:, force_delete: false)
    validate_confirmation_token!(confirmation_token)
    if force_delete
      raise NotImplementedError, "full deletion of users is not implemented yet"
    end
    ActiveRecord::Base.transaction do
      # OauthIdentities can be completely deleted
      OauthIdentity.unscoped.where(user_id: user.id).delete_all
      user.email = "#{SecureRandom.hex(10)}@deleted.user"
      user.name = "Deleted User"
      user.image.purge if user.image.attached?
      user.save!
      # API tokens are marked as deleted but not destroyed
      ApiToken.unscoped.where(user_id: user.id).update_all(deleted_at: Time.current)
      User.unscoped.where(parent_id: user.id).each do |simulated_user|
        # Simulated users are not modified, but their API tokens are marked as deleted
        ApiToken.unscoped.where(user_id: simulated_user.id).update_all(deleted_at: Time.current)
      end
      StudioUser.unscoped.where(user_id: user.id).each do |studio_user|
        studio_user_is_sole_admin = studio_user.is_admin? && studio_user.studio.admins.count == 1
        if studio_user_is_sole_admin
          # If the user is the only admin of the studio, we need to assign a new admin
          other_studio_users = studio_user.studio.studio_users.where.not(user_id: user.id).where(archived_at: nil)
          representatives =  other_studio_users.where_has_role('representative')
          new_admin = representatives.first || other_studio_users.first
          if new_admin
            new_admin.add_role!('admin')
          else
            # If there are no other users, ??? Need to handle this case
            # TODO
          end
        end
        studio_user.archived_at = Time.current
        studio_user.save!
      end
      TenantUser.unscoped.where(user_id: user.id).each do |tenant_user|
        tenant_user.update!(
          display_name: "Deleted User",
          handle: "#{SecureRandom.hex(10)}-deleted",
          settings: tenant_user.settings.merge(
            scratchpad: { text: "deleted user", json: {} },
            pinned: {},
          ),
          archived_at: Time.current,
        )
      end
    end
    "PII for user '#{user.id}' has been removed and the user has been marked as deleted."
  end

  def delete_note!(note:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    note_title = note.title
    note_id = note.id
    raise "note.id returned nil" if note_id.nil?
    ActiveRecord::Base.transaction do
      # Delete all associated data
      NoteHistoryEvent.unscoped.where(note_id: note.id).each do |event|
        event.destroy!
      end
      # Link where the note is the from_linkable or the to_linkable
      Link.unscoped.where(from_linkable: note).or(Link.unscoped.where(to_linkable: note)).each do |link|
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

  def delete_decision!(decision:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    decision_question = decision.question
    decision_id = decision.id
    raise "decision.id returned nil" if decision_id.nil?
    ActiveRecord::Base.transaction do
      # Delete all associated data
      Approval.unscoped.where(decision_id: decision.id).each do |approval|
        approval.destroy!
      end
      Option.unscoped.where(decision_id: decision.id).each do |option|
        option.destroy!
      end
      DecisionParticipant.unscoped.where(decision_id: decision.id).each do |participant|
        participant.destroy!
      end
      Link.unscoped.where(from_linkable: decision).or(Link.unscoped.where(to_linkable: decision)).each do |link|
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

  def delete_commitment!(commitment:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    commitment_title = commitment.title
    commitment_id = commitment.id
    raise "commitment.id returned nil" if commitment_id.nil?
    ActiveRecord::Base.transaction do
      # Delete all associated data
      CommitmentParticipant.unscoped.where(commitment_id: commitment.id).each do |participant|
        participant.destroy!
      end
      Link.unscoped.where(from_linkable: commitment).or(Link.unscoped.where(to_linkable: commitment)).each do |link|
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

  def delete_representation_session!(representation_session:, confirmation_token:)
    validate_confirmation_token!(confirmation_token)
    # Delete all associated data
    raise NotImplementedError, "delete_representation_session! is not implemented yet"
  end

end