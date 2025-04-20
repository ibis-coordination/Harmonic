require "test_helper"

class DecisionTest < ActiveSupport::TestCase
  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
    User.create!(email: email, name: name, user_type: user_type)
  end

  def create_studio(tenant:, created_by:, name: "Test Studio", handle: "test-studio")
    Studio.create!(tenant: tenant, created_by: created_by, name: name, handle: handle)
  end

  test "Decision.create works" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: true
    )

    assert decision.persisted?
    assert_equal "Test Decision", decision.question
    assert_equal "This is a test decision.", decision.description
    assert_equal tenant, decision.tenant
    assert_equal studio, decision.studio
    assert_equal user, decision.created_by
    assert_equal user, decision.updated_by
    assert decision.options_open
  end

  test "Decision requires a question" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.new(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      description: "This is a test decision without a question."
    )

    assert_not decision.valid?
    assert_includes decision.errors[:question], "can't be blank"
  end

  test "Decision.voter_count returns the correct count" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: true
    )

    participant = DecisionParticipant.create!(decision: decision, user: user)
    option = Option.create!(decision: decision, title: "Test Option", decision_participant: participant)
    [1, 2, 3].each do |i|
      user = create_user(email: "u#{i}@example.com")
      participant = DecisionParticipant.create!(decision: decision, user: user, participant_uid: "u#{i}")
      Approval.create!(decision: decision, decision_participant: participant, option: option, value: true, stars: 0)
      assert_equal i, decision.voter_count
    end
  end

  test "Decision.results returns the correct results" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: true
    )
    participant = DecisionParticipant.create!(decision: decision, user: user)
    options = [
      Option.create!(decision: decision, title: "Option 1", decision_participant: participant),
      Option.create!(decision: decision, title: "Option 2", decision_participant: participant)
    ]
    approval1 = Approval.create!(decision: decision, decision_participant: participant, option: options.first, value: true, stars: 0)
    approval2 = Approval.create!(decision: decision, decision_participant: participant, option: options.last, value: false, stars: 1)
    results = decision.results
    assert_equal 2, results.size
    assert_equal options.first.id, results[0][:option_id]
    assert_equal options.last.id, results[1][:option_id]
    assert_equal 1, results[0].approved_yes
    assert_equal 0, results[1].approved_yes
    assert_equal 0, results[0].approved_no
    assert_equal 1, results[1].approved_no
    assert_equal 0, results[0].stars
    assert_equal 1, results[1].stars
  end

  test "Decision.can_add_options? returns true for creator" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: false
    )

    participant = DecisionParticipant.create!(decision: decision, user: user)
    assert decision.can_add_options?(participant)
  end

  test "Decision.can_add_options? returns false for non-creator when options are closed" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: false
    )

    non_creator = create_user(email: "non_creator@example.com", name: "Non-Creator")
    participant = DecisionParticipant.create!(decision: decision, user: non_creator)
    assert_not decision.can_add_options?(participant)
  end

  test "Decision.can_add_options? returns true for non-creator when options are open" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: true
    )

    non_creator = create_user(email: "non_creator@example.com", name: "Non-Creator")
    participant = DecisionParticipant.create!(decision: decision, user: non_creator)
    assert decision.can_add_options?(participant)
  end

  test "Decision.api_json includes expected fields" do
    tenant = create_tenant
    user = create_user
    studio = create_studio(tenant: tenant, created_by: user)

    decision = Decision.create!(
      tenant: tenant,
      studio: studio,
      created_by: user,
      updated_by: user,
      question: "Test Decision",
      description: "This is a test decision.",
      options_open: true
    )

    json = decision.api_json
    assert_equal decision.id, json[:id]
    assert_equal decision.question, json[:question]
    assert_equal decision.description, json[:description]
    assert_equal decision.options_open, json[:options_open]
    assert_equal decision.created_at, json[:created_at]
    assert_equal decision.updated_at, json[:updated_at]
  end
end
