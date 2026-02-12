# typed: true

# This class is responsible for managing the business logic around
# creating decision participants and inviting users to participate.
# Users are required - anonymous participation is not supported.
class DecisionParticipantManager
  extend T::Sig

  sig { params(decision: Decision, user: User, name: T.nilable(String)).void }
  def initialize(decision:, user:, name: nil)
    @decision = decision
    @user = user
    @name = name
  end

  sig { returns(DecisionParticipant) }
  def find_or_create_participant
    participant = DecisionParticipant.find_by(
      decision: @decision,
      user: @user,
    )
    if participant.nil?
      participant = DecisionParticipant.create!(
        decision: @decision,
        user: @user,
        participant_uid: SecureRandom.uuid,
        name: @name,
      )
    end
    participant
  end
end