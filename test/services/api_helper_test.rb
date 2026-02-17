require "test_helper"

class ApiHelperTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    # Collective.scope_thread_to_collective sets the current studio and tenant.
    # In controller actions, this is handled by ApplicationController
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )
  end

  test "ApiHelper.create_studio creates a collective" do
    params = {
      name: "Studio Name",
      handle: "studio-handle",
      description: "This is a test studio.",
      timezone: "Pacific Time (US & Canada)",
      tempo: "daily",
      synchronization_mode: "improv"
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Collective,
      current_resource: nil,
      params: params,
      request: {}
    )
    collective = api_helper.create_studio
    assert collective.persisted?
    assert_equal params[:name], collective.name
    assert_equal params[:handle], collective.handle
    assert_equal params[:description], collective.description
    assert_equal params[:timezone], collective.timezone.name
    assert_equal params[:tempo], collective.tempo
    assert_equal params[:synchronization_mode], collective.synchronization_mode
    assert_equal @tenant, collective.tenant
    assert_equal @user, collective.created_by
  end

  test "ApiHelper.create_note creates a note" do
    params = {
      title: "Note Title",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Note,
      current_resource: nil,
      params: params,
      request: {}
    )
    note = api_helper.create_note
    assert note.persisted?
    assert_equal params[:title], note.title
    assert_equal params[:text], note.text
    assert_equal @user, note.created_by
  end

  test "ApiHelper.create_decision creates a decision" do
    params = {
      question: "What is the best approach?",
      description: "Discussing the best approach for the project.",
      deadline: Time.current + 1.week
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Decision,
      current_resource: nil,
      params: params,
      request: {}
    )
    decision = api_helper.create_decision
    assert decision.persisted?
    assert_equal params[:question], decision.question
    assert_equal params[:description], decision.description
    assert_equal @user, decision.created_by
  end

  test "ApiHelper.confirm_read raises error for invalid resource model" do
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Decision,
      current_resource: Decision.new,
      params: {},
      request: {}
    )
    assert_raises(RuntimeError, "Expected resource model Note, not Decision") do
      api_helper.confirm_read
    end
  end

  test "ApiHelper.confirm_read confirms read for a note" do
    note = create_note
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Note,
      current_resource: note,
      params: {},
      request: {}
    )
    history_event = api_helper.confirm_read
    assert history_event.persisted?
    assert_equal note, history_event.note
    assert_equal @user, history_event.user
  end

  test "ApiHelper.update_note updates note attributes" do
    note = create_note
    params = { title: "New Title", text: "Updated text." }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Note,
      current_resource: note,
      model_params: params,
      params: params,
      request: {}
    )
    updated_note = api_helper.update_note
    assert_equal "New Title", updated_note.title
    assert_equal "Updated text.", updated_note.text
    assert_equal @user, updated_note.updated_by
  end

  test "ApiHelper.create_decision_options creates decision options" do
    decision = create_decision
    params = { titles: ["Option Title"] }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    options = api_helper.create_decision_options
    assert_equal 1, options.count
    assert options.first.persisted?
    assert_equal "Option Title", options.first.title
    assert_equal decision, options.first.decision
  end

  test "ApiHelper.create_votes creates votes for multiple decision options" do
    decision = create_decision
    option1 = create_option(decision: decision, title: "Option A")
    option2 = create_option(decision: decision, title: "Option B")
    params = {
      votes: [
        { option_title: option1.title, accept: true, prefer: true },
        { option_title: option2.title, accept: true, prefer: false },
      ]
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    votes = api_helper.create_votes
    assert_equal 2, votes.count
    vote1 = votes.find { |v| v.option == option1 }
    vote2 = votes.find { |v| v.option == option2 }
    assert vote1.persisted?
    assert_equal 1, vote1.accepted
    assert_equal 1, vote1.preferred
    assert vote2.persisted?
    assert_equal 1, vote2.accepted
    assert_equal 0, vote2.preferred
  end

  test "ApiHelper.create_votes creates single vote when array has one element" do
    decision = create_decision
    option = create_option(decision: decision)
    params = {
      votes: [
        { option_title: option.title, accepted: false, preferred: false }
      ]
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    votes = api_helper.create_votes
    assert_equal 1, votes.count
    vote = votes.first
    assert vote.persisted?
    assert_equal 0, vote.accepted
    assert_equal 0, vote.preferred
    assert_equal option, vote.option
    assert_equal decision, vote.decision
    assert_equal @user, vote.decision_participant.user
  end

  test "ApiHelper.create_votes raises error for missing option" do
    decision = create_decision
    params = {
      votes: [
        { option_title: "Nonexistent Option", accept: true, prefer: false }
      ]
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    assert_raises ArgumentError do
      api_helper.create_votes
    end
  end

  test "ApiHelper.start_user_representation_session creates a user representation session" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    grant.accept!

    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: {},
      request: {}
    )

    rep_session = api_helper.start_user_representation_session(grant: grant)

    assert rep_session.persisted?
    assert_nil rep_session.collective_id
    assert_equal @user, rep_session.representative_user
    # effective_user is the granting_user (the person being represented)
    assert_equal grant.granting_user, rep_session.effective_user
    assert_equal grant, rep_session.trustee_grant
    assert rep_session.confirmed_understanding
  end

  test "ApiHelper.start_user_representation_session raises error for inactive grant" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    # Grant is pending, not active

    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: {},
      request: {}
    )

    assert_raises ArgumentError do
      api_helper.start_user_representation_session(grant: grant)
    end
  end

  test "ApiHelper.start_user_representation_session raises error for wrong user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: other_user,  # other_user is trustee, not @user
      permissions: { "create_notes" => true },
    )
    grant.accept!

    api_helper = ApiHelper.new(
      current_user: @user,  # @user is NOT the trustee user
      current_collective: @collective,
      current_tenant: @tenant,
      params: {},
      request: {}
    )

    assert_raises ArgumentError do
      api_helper.start_user_representation_session(grant: grant)
    end
  end

end