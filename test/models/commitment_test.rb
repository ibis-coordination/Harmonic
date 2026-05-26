require "test_helper"

class CommitmentTest < ActiveSupport::TestCase
  # NOTE: create_tenant, create_user, create_collective helpers are inherited from test_helper.rb

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

  test "Commitment.title length is capped at MAX_TITLE_LENGTH" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "x" * (Commitment::MAX_TITLE_LENGTH + 1),
      description: "valid",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:title], "is too long (maximum is #{Commitment::MAX_TITLE_LENGTH} characters)"
  end

  test "Commitment.description length is capped at MAX_DESCRIPTION_LENGTH" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Valid",
      description: "x" * (Commitment::MAX_DESCRIPTION_LENGTH + 1),
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:description], "is too long (maximum is #{Commitment::MAX_DESCRIPTION_LENGTH} characters)"
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
    collective = create_collective(tenant: tenant, created_by: user, handle: "leave-collective-#{SecureRandom.hex(4)}")

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
    collective = create_collective(tenant: tenant, created_by: user, handle: "count-collective-#{SecureRandom.hex(4)}")

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

  # Subtype tests

  test "Commitment defaults to action subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Default subtype",
      description: "Test description",
      critical_mass: 3,
      deadline: 1.week.from_now
    )

    assert_equal "action", commitment.subtype
    assert commitment.is_action?
    assert_not commitment.is_calendar_event?
    assert_not commitment.is_policy?
  end

  test "Commitment can be created with explicit subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    Commitment::SUBTYPES.each do |subtype|
      attrs = {
        tenant: tenant,
        collective: collective,
        created_by: user,
        updated_by: user,
        title: "#{subtype} commitment",
        description: "Test description",
        critical_mass: 3,
        deadline: 1.week.from_now,
        subtype: subtype,
      }
      if subtype == "calendar_event"
        attrs[:starts_at] = 1.week.from_now
        attrs[:ends_at] = 1.week.from_now + 1.hour
      end
      commitment = Commitment.create!(attrs)

      assert_equal subtype, commitment.subtype
    end
  end

  test "Commitment rejects invalid subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Invalid subtype",
      critical_mass: 3,
      deadline: 1.week.from_now,
      subtype: "invalid"
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:subtype], "is not included in the list"
  end

  test "Commitment api_json includes subtype" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    starts = 1.week.from_now
    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Calendar event",
      description: "Test description",
      critical_mass: 5,
      deadline: 1.week.from_now,
      subtype: "calendar_event",
      starts_at: starts,
      ends_at: starts + 1.hour
    )

    json = commitment.api_json
    assert_equal "calendar_event", json[:subtype]
  end

  # closed? must always return a boolean even for records with nil deadline.
  # Historical records (created before the deadline validation existed for a
  # subtype) can have nil deadlines; closed? is called from feed rendering
  # and other hot paths, and returning nil violates the Sorbet sig.
  test "closed? returns false (not nil) when deadline is nil" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant, collective: collective,
      created_by: user, updated_by: user,
      title: "Legacy", subtype: "action",
      critical_mass: 1, deadline: 1.week.from_now,
    )
    commitment.save!
    # Bypass validation to simulate legacy data with nil deadline
    commitment.update_columns(deadline: nil)

    assert_equal false, commitment.reload.closed?
  end

  # Policy subtype tests
  #
  # Policies are functionally identical to actions (same critical_mass,
  # deadline, closing behavior). Only the language differs: members "sign"
  # instead of "join", and the metric is "signatories" instead of
  # "participants".

  test "Policy commitment requires deadline and critical_mass like actions" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Be kind",
      subtype: "policy"
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:deadline], "can't be blank"
    assert_includes commitment.errors[:critical_mass], "can't be blank"
  end

  test "Policy commitment closes when deadline passes" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Be kind",
      subtype: "policy",
      critical_mass: 3,
      deadline: 1.day.ago
    )

    assert commitment.closed?
  end

  test "Policy commitment metric_name is 'signatories'" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Be kind",
      subtype: "policy",
      critical_mass: 3,
      deadline: 1.week.from_now
    )

    assert_equal "signatories", commitment.metric_name
  end

  test "Action commitment metric_name is 'participants'" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Plant trees",
      subtype: "action",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    assert_equal "participants", commitment.metric_name
  end

  # Calendar event subtype tests

  test "Calendar event requires starts_at and ends_at" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Team meeting",
      subtype: "calendar_event"
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:starts_at], "can't be blank"
    assert_includes commitment.errors[:ends_at], "can't be blank"
  end

  test "Calendar event rejects ends_at <= starts_at" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    starts = 1.week.from_now
    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Team meeting",
      subtype: "calendar_event",
      starts_at: starts,
      ends_at: starts - 1.hour,
      critical_mass: 1,
      deadline: starts
    )

    assert_not commitment.valid?
    assert_includes commitment.errors[:ends_at], "must be after starts_at"
  end

  test "Calendar event is valid with starts_at and ends_at" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    starts = 1.week.from_now
    commitment = Commitment.new(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Team meeting",
      subtype: "calendar_event",
      starts_at: starts,
      ends_at: starts + 1.hour,
      location: "Conference Room A",
      critical_mass: 1,
      deadline: starts
    )

    assert commitment.valid?, commitment.errors.full_messages.to_sentence
  end

  test "Calendar event metric_name is 'attendees'" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    starts = 1.week.from_now
    commitment = Commitment.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      title: "Team meeting",
      subtype: "calendar_event",
      starts_at: starts,
      ends_at: starts + 1.hour,
      critical_mass: 1,
      deadline: starts
    )

    assert_equal "attendees", commitment.metric_name
  end

  test "Calendar event upcoming?/in_progress?/past?" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    future = Commitment.create!(
      tenant: tenant, collective: collective, created_by: user, updated_by: user,
      title: "Future event", subtype: "calendar_event",
      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour,
      critical_mass: 1, deadline: 1.day.from_now
    )
    assert future.upcoming?
    assert_not future.in_progress?
    assert_not future.past?

    ongoing = Commitment.create!(
      tenant: tenant, collective: collective, created_by: user, updated_by: user,
      title: "Ongoing event", subtype: "calendar_event",
      starts_at: 30.minutes.ago, ends_at: 30.minutes.from_now,
      critical_mass: 1, deadline: 30.minutes.from_now
    )
    assert_not ongoing.upcoming?
    assert ongoing.in_progress?
    assert_not ongoing.past?

    past = Commitment.create!(
      tenant: tenant, collective: collective, created_by: user, updated_by: user,
      title: "Past event", subtype: "calendar_event",
      starts_at: 2.hours.ago, ends_at: 1.hour.ago,
      critical_mass: 1, deadline: 2.hours.ago
    )
    assert_not past.upcoming?
    assert_not past.in_progress?
    assert past.past?
  end

  test "Calendar event api_json includes starts_at, ends_at, location" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)

    starts = 1.week.from_now
    commitment = Commitment.create!(
      tenant: tenant, collective: collective, created_by: user, updated_by: user,
      title: "Team meeting", subtype: "calendar_event",
      starts_at: starts, ends_at: starts + 1.hour, location: "Room A",
      critical_mass: 1, deadline: starts
    )

    json = commitment.api_json
    assert_equal "Room A", json[:location]
    assert json[:starts_at].present?
    assert json[:ends_at].present?
  end
end
