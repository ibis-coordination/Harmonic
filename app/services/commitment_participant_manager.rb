# typed: true

# This class is responsible for managing the business logic around
# creating commitment participants and inviting users to participate.
# Users are required - anonymous participation is not supported.
class CommitmentParticipantManager
  extend T::Sig

  sig { params(commitment: Commitment, user: User).void }
  def initialize(commitment:, user:)
    @commitment = commitment
    @user = user
  end

  sig { returns(CommitmentParticipant) }
  def find_or_create_participant
    participant = CommitmentParticipant.find_by(
      commitment: @commitment,
      user: @user,
    )
    if participant.nil?
      participant = CommitmentParticipant.create!(
        commitment: @commitment,
        user: @user,
        participant_uid: SecureRandom.uuid,
      )
    end
    participant
  end
end
