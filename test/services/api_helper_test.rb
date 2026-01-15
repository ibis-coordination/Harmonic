require "test_helper"

class ApiHelperTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    # Superagent.scope_thread_to_superagent sets the current studio and tenant.
    # In controller actions, this is handled by ApplicationController
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )
  end

  test "ApiHelper.create_studio creates a superagent" do
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
      current_superagent: @superagent,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Superagent,
      current_resource: nil,
      params: params,
      request: {}
    )
    superagent = api_helper.create_studio
    assert superagent.persisted?
    assert_equal params[:name], superagent.name
    assert_equal params[:handle], superagent.handle
    assert_equal params[:description], superagent.description
    assert_equal params[:timezone], superagent.timezone.name
    assert_equal params[:tempo], superagent.tempo
    assert_equal params[:synchronization_mode], superagent.synchronization_mode
    assert_equal @tenant, superagent.tenant
    assert_equal @user, superagent.created_by
  end

  test "ApiHelper.create_note creates a note" do
    params = {
      title: "Note Title",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_superagent: @superagent,
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
      current_superagent: @superagent,
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
      current_superagent: @superagent,
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
      current_superagent: @superagent,
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
      current_superagent: @superagent,
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

  test "ApiHelper.create_decision_option creates a decision option" do
    decision = create_decision
    params = { title: "Option Title" }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_superagent: @superagent,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    option = api_helper.create_decision_option
    assert option.persisted?
    assert_equal params[:title], option.title
    assert_equal decision, option.decision
  end

  test "ApiHelper.vote creates or updates a vote for a decision option (accept + prefer)" do
    decision = create_decision
    option = create_option(decision: decision)
    params = {
      option_title: option.title,
      accept: true,
      prefer: true
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_superagent: @superagent,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    vote = api_helper.vote
    assert vote.persisted?
    assert_equal 1, vote.accepted
    assert_equal 1, vote.preferred
    assert_equal option, vote.option
    assert_equal decision, vote.decision
    assert_equal @user, vote.decision_participant.user
  end

  test "ApiHelper.vote creates or updates a vote for a decision option (accepted + preferred)" do
    decision = create_decision
    option = create_option(decision: decision)
    params = {
      option_title: option.title,
      accepted: false,
      preferred: false
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_superagent: @superagent,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    vote = api_helper.vote
    assert vote.persisted?
    assert_equal 0, vote.accepted
    assert_equal 0, vote.preferred
    assert_equal option, vote.option
    assert_equal decision, vote.decision
    assert_equal @user, vote.decision_participant.user
  end

end