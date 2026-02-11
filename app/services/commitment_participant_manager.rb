# typed: true

# This class is responsible for managing the business logic around
# creating commitment participants and inviting users to participate.
class CommitmentParticipantManager
  extend T::Sig

  sig { params(commitment: Commitment, user: T.nilable(User), participant_uid: T.nilable(String)).void }
  def initialize(commitment:, user: nil, participant_uid: nil)
    @commitment = commitment
    @user = user
    @participant_uid = participant_uid
    # TODO - add validations
  end

  sig { returns(CommitmentParticipant) }
  def find_or_create_participant
    if @user
      # User takes precedence over participant_uid.
      # TODO - maybe provide users the option to claim participant_uid after logging in.
      @participant_uid = nil
      participant = find_or_create_by_user
    elsif @participant_uid
      participant = find_or_create_by_participant_uid
    else
      @participant_uid = generate_participant_uid
      participant = find_or_create_by_participant_uid
    end
    participant
  end

  private

  sig { returns(String) }
  def generate_participant_uid
    SecureRandom.uuid
  end

  sig { returns(CommitmentParticipant) }
  def find_or_create_by_participant_uid
    if @participant_uid.nil?
      raise 'participant_uid must be present to find or create by participant_uid'
    elsif @user
      raise 'user cannot be present when finding or creating by participant_uid'
    end
    participant = CommitmentParticipant.find_by(
      commitment: @commitment,
      participant_uid: @participant_uid,
    )
    if participant && participant.user
      # If the participant is associated with a user,
      # but the user is not logged in, then we cannot use this participant record
      participant = nil
      @participant_uid = generate_participant_uid
    end
    if participant.nil?
      participant = CommitmentParticipant.create!(
        commitment: @commitment,
        user: @user,
        participant_uid: @participant_uid,
      )
    end
    participant
  end

  sig { returns(CommitmentParticipant) }
  def find_or_create_by_user
    if @user.nil?
      raise 'user must be present to find or create by user'
    elsif @participant_uid
      raise 'participant_uid cannot be present when finding or creating by user'
    end
    participant = CommitmentParticipant.find_by(
      commitment: @commitment,
      user: @user,
    )
    if participant.nil?
      @participant_uid = generate_participant_uid
      participant = CommitmentParticipant.create!(
        commitment: @commitment,
        user: @user,
        participant_uid: @participant_uid,
      )
    end
    participant
  end
end