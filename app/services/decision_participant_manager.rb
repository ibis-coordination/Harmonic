# typed: true

# This class is responsible for managing the business logic around
# creating decision participants and inviting users to participate.
class DecisionParticipantManager
  extend T::Sig

  sig { params(decision: Decision, user: T.nilable(User), participant_uid: T.nilable(String), name: T.nilable(String)).void }
  def initialize(decision:, user: nil, participant_uid: nil, name: nil)
    @decision = decision
    @user = user
    @participant_uid = participant_uid
    @name = name
    # TODO - add validations
  end

  sig { returns(DecisionParticipant) }
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

  sig { returns(DecisionParticipant) }
  def find_or_create_by_participant_uid
    if @participant_uid.nil?
      raise 'participant_uid must be present to find or create by participant_uid'
    elsif @user
      raise 'user cannot be present when finding or creating by participant_uid'
    end
    participant = DecisionParticipant.find_by(
      decision: @decision,
      participant_uid: @participant_uid,
    )
    if participant && participant.user
      # If the participant is associated with a user, 
      # but the user is not logged in, then we cannot use this participant record
      participant = nil
      @participant_uid = generate_participant_uid
    end
    if participant.nil?
      participant = DecisionParticipant.create!(
        decision: @decision,
        user: @user,
        participant_uid: @participant_uid,
        name: @name,
      )
    end
    participant
  end

  sig { returns(DecisionParticipant) }
  def find_or_create_by_user
    if @user.nil?
      raise 'user must be present to find or create by user'
    elsif @participant_uid
      raise 'participant_uid cannot be present when finding or creating by user'
    end
    participant = DecisionParticipant.find_by(
      decision: @decision,
      user: @user,
    )
    if participant.nil?
      @participant_uid = generate_participant_uid
      participant = DecisionParticipant.create!(
        decision: @decision,
        user: @user,
        participant_uid: @participant_uid,
        name: @name,
      )
    end
    participant
  end
end