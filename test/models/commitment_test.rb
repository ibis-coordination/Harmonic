require "test_helper"

class CommitmentTest < ActiveSupport::TestCase
  # Note: create_tenant, create_user, create_collective helpers are inherited from test_helper.rb

  test "Commitment.create works" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Commitment",
      description: "This is a test commitment.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    assert commitment.persisted?
    assert_equal "Test Commitment", commitment.title
    assert_equal "This is a test commitment.", commitment.description
    assert_equal 5, commitment.critical_mass
    assert commitment.deadline > Time.current
    assert_equal tenant, commitment.tenant
    assert_equal collective, commitment.collective
    assert_equal user, commitment.created_by
    assert_equal user, commitment.updated_by
  end

  test "Commitment requires a title" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      description: "This is a test commitment without a title.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:title], "can't be blank"
  end

  test "Commitment requires a critical mass greater than 0" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Commitment",
      description: "This is a test commitment.",
      critical_mass: 0,
      deadline: 1.week.from_now
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:critical_mass], "must be greater than 0"
  end

  test "Commitment requires a deadline" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Commitment",
      description: "This is a test commitment.",
      critical_mass: 5
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:deadline], "can't be blank"
  end

  test "Commitment.critical_mass_achieved? returns true when critical mass is met" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Commitment",
      description: "This is a test commitment.",
      critical_mass: 2,
      deadline: 1.week.from_now
    )

    commitment.join_commitment!(user)
    assert_not commitment.critical_mass_achieved?
    another_user = create_user(email: "another@example.com")
    commitment.join_commitment!(another_user)
    assert commitment.critical_mass_achieved?
  end

  test "Commitment.critical_mass_achieved? returns false when critical mass is not met" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Commitment",
      description: "This is a test commitment.",
      critical_mass: 2,
      deadline: 1.week.from_now
    )

    commitment.join_commitment!(user)

    assert_not commitment.critical_mass_achieved?
  end

  test "Commitment.progress_percentage calculates correctly" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Commitment",
      description: "This is a test commitment.",
      critical_mass: 4,
      deadline: 1.week.from_now
    )

    commitment.join_commitment!(user)
    assert_equal 25, commitment.progress_percentage

    another_user = create_user(email: "another@example.com")
    commitment.join_commitment!(another_user)
    assert_equal 50, commitment.progress_percentage
  end

  test "Commitment.api_json includes expected fields" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Test Commitment",
      description: "This is a test commitment.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    json = commitment.api_json
    assert_equal commitment.id, json[:id]
    assert_equal commitment.title, json[:title]
    assert_equal commitment.description, json[:description]
    assert_equal commitment.critical_mass, json[:critical_mass]
    assert_equal commitment.deadline, json[:deadline]
    assert_equal commitment.created_at, json[:created_at]
    assert_equal commitment.updated_at, json[:updated_at]
  end

  # === Join and Leave Tests ===

  test "User can leave commitment by updating participant" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "leave-studio-#{SecureRandom.hex(4)}")

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Leavable Commitment",
      description: "Users can leave this.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    participant = commitment.join_commitment!(user)
    assert_equal 1, commitment.participant_count

    # Leave by setting committed to false
    participant.committed = false
    participant.save!
    commitment.reload
    assert_equal 0, commitment.participant_count
  end

  # === Deadline Status Tests ===

  test "Commitment with future deadline is not closed" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "open-commitment-#{SecureRandom.hex(4)}")

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Open Commitment",
      description: "This commitment is still open.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    assert_not commitment.closed?
  end

  test "Commitment with past deadline is closed" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "closed-commitment-#{SecureRandom.hex(4)}")

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Closed Commitment",
      description: "This commitment is closed.",
      critical_mass: 5,
      deadline: 1.day.ago
    )

    assert commitment.closed?
  end

  # === Participant Count Tests ===

  test "Commitment.participant_count returns correct count" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "count-studio-#{SecureRandom.hex(4)}")

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Count Commitment",
      description: "Testing participant count.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    commitment.join_commitment!(user)
    user2 = create_user(email: "user2_#{SecureRandom.hex(4)}@example.com")
    commitment.join_commitment!(user2)
    user3 = create_user(email: "user3_#{SecureRandom.hex(4)}@example.com")
    commitment.join_commitment!(user3)

    assert_equal 3, commitment.participant_count
  end

  # === Pin Tests ===

  test "Commitment can be pinned" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "pin-commitment-#{SecureRandom.hex(4)}")

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Pinnable Commitment",
      description: "This commitment can be pinned.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    commitment.pin!(tenant: tenant, collective: collective, user: user)
    assert commitment.is_pinned?(tenant: tenant, collective: collective, user: user)
  end

  test "Commitment can be unpinned" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "unpin-commitment-#{SecureRandom.hex(4)}")

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Unpinnable Commitment",
      description: "This commitment can be unpinned.",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    commitment.pin!(tenant: tenant, collective: collective, user: user)
    commitment.unpin!(tenant: tenant, collective: collective, user: user)
    assert_not commitment.is_pinned?(tenant: tenant, collective: collective, user: user)
  end

  # === Status When Critical Mass Achieved ===

  test "Commitment shows achieved status after critical mass" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user, handle: "achieved-#{SecureRandom.hex(4)}")

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Achievable Commitment",
      description: "Test description",
      critical_mass: 2,
      deadline: 1.week.from_now
    )

    commitment.join_commitment!(user)
    assert_not commitment.critical_mass_achieved?
    assert_equal 50, commitment.progress_percentage

    user2 = create_user(email: "achieve2_#{SecureRandom.hex(4)}@example.com")
    commitment.join_commitment!(user2)
    assert commitment.critical_mass_achieved?
    assert_equal 100, commitment.progress_percentage
  end
end