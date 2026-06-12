# typed: false

require "test_helper"

class CommitmentParticipantTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )
  end

  test "requires user" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    participant = CommitmentParticipant.new(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: nil,
      committed_at: Time.current
    )

    assert_not participant.valid?
    assert_includes participant.errors[:user], "must exist"
  end

  test "valid with user" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    participant = CommitmentParticipant.new(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: @user,
      committed_at: Time.current
    )

    assert participant.valid?
  end

  test "authenticated? returns true" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    participant = CommitmentParticipant.create!(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: @user,
      committed_at: Time.current
    )

    assert participant.authenticated?
  end

  test "committing emits a commitment.joined event with the joiner as actor" do
    commitment = create_commitment_with_critical_mass(2)
    joiner = create_collective_member("joiner-1")

    join_commitment(commitment, joiner)

    event = Event.where(event_type: "commitment.joined", subject: commitment).last
    assert_not_nil event, "Expected a commitment.joined event"
    assert_equal joiner.id, event.actor_id
    assert_equal commitment.truncated_id, event.metadata["truncated_id"]
  end

  test "creating an uncommitted participant emits no events" do
    commitment = create_commitment_with_critical_mass(2)
    joiner = create_collective_member("joiner-2")

    CommitmentParticipantManager.new(commitment: commitment, user: joiner).find_or_create_participant

    assert_nil Event.where(event_type: "commitment.joined", subject: commitment).last
  end

  test "join that reaches critical mass emits commitment.critical_mass" do
    commitment = create_commitment_with_critical_mass(2)
    first = create_collective_member("cm-first")
    second = create_collective_member("cm-second")

    join_commitment(commitment, first)
    assert_nil Event.where(event_type: "commitment.critical_mass", subject: commitment).last,
               "Critical mass should not fire below the threshold"

    join_commitment(commitment, second)
    event = Event.where(event_type: "commitment.critical_mass", subject: commitment).last
    assert_not_nil event, "Expected a commitment.critical_mass event at the threshold"
    assert_equal second.id, event.actor_id
  end

  test "joins beyond critical mass do not re-fire commitment.critical_mass" do
    commitment = create_commitment_with_critical_mass(1)
    first = create_collective_member("over-first")
    second = create_collective_member("over-second")

    join_commitment(commitment, first)
    join_commitment(commitment, second)

    assert_equal 1, Event.where(event_type: "commitment.critical_mass", subject: commitment).count
  end

  test "leaving and rejoining re-fires joined and a re-crossed critical mass" do
    commitment = create_commitment_with_critical_mass(1)
    joiner = create_collective_member("rejoiner")

    participant = join_commitment(commitment, joiner)
    participant.update!(committed_at: nil)
    participant.update!(committed_at: Time.current)

    assert_equal 2, Event.where(event_type: "commitment.joined", subject: commitment).count
    assert_equal 2, Event.where(event_type: "commitment.critical_mass", subject: commitment).count
  end

  test "updating an already-committed participant does not re-emit joined" do
    commitment = create_commitment_with_critical_mass(2)
    joiner = create_collective_member("updater")

    participant = join_commitment(commitment, joiner)
    participant.update!(participant_uid: SecureRandom.uuid)

    assert_equal 1, Event.where(event_type: "commitment.joined", subject: commitment).count
  end

  test "no join events while importing data" do
    commitment = create_commitment_with_critical_mass(1)
    joiner = create_collective_member("importer")

    Current.importing_data = true
    begin
      join_commitment(commitment, joiner)
    ensure
      Current.importing_data = false
    end

    assert_nil Event.where(event_type: "commitment.joined", subject: commitment).last
    assert_nil Event.where(event_type: "commitment.critical_mass", subject: commitment).last
  end

  private

  def create_commitment_with_critical_mass(critical_mass)
    Commitment.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Critical mass commitment",
      description: "Test commitment",
      critical_mass: critical_mass,
      deadline: 1.week.from_now
    )
  end

  def create_collective_member(handle)
    user = create_user(email: "#{handle}@example.com", name: handle)
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def join_commitment(commitment, user)
    participant = CommitmentParticipantManager.new(commitment: commitment, user: user).find_or_create_participant
    participant.committed = true
    participant.save!
    participant
  end
end
