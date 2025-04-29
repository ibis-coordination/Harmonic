require "test_helper"

class ApiHelperTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @studio = @global_studio
    @user = @global_user
    # Studio.scope_thread_to_studio sets the current studio and tenant.
    # In controller actions, this is handled by ApplicationController
    Studio.scope_thread_to_studio(
      subdomain: @tenant.subdomain,
      handle: @studio.handle
    )
  end

  test "ApiHelper.create_studio creates a studio" do
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
      current_studio: @studio,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Studio,
      current_resource: nil,
      params: params,
      request: {}
    )
    studio = api_helper.create_studio
    assert studio.persisted?
    assert_equal params[:name], studio.name
    assert_equal params[:handle], studio.handle
    assert_equal params[:description], studio.description
    assert_equal params[:timezone], studio.timezone.name
    assert_equal params[:tempo], studio.tempo
    assert_equal params[:synchronization_mode], studio.synchronization_mode
    assert_equal @tenant, studio.tenant
    assert_equal @user, studio.created_by
  end

  test "ApiHelper.create_note creates a note" do
    params = {
      title: "Note Title",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_studio: @studio,
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
      current_studio: @studio,
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
      current_studio: @studio,
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
      current_studio: @studio,
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
      current_studio: @studio,
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
      current_studio: @studio,
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
      current_studio: @studio,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    approval = api_helper.vote
    assert approval.persisted?
    assert_equal 1, approval.value
    assert_equal 1, approval.stars
    assert_equal option, approval.option
    assert_equal decision, approval.decision
    assert_equal @user, approval.decision_participant.user
  end

  test "ApiHelper.vote creates or updates a vote for a decision option (value + stars)" do
    decision = create_decision
    option = create_option(decision: decision)
    params = {
      option_title: option.title,
      value: false,
      stars: false
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_studio: @studio,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    approval = api_helper.vote
    assert approval.persisted?
    assert_equal 0, approval.value
    assert_equal 0, approval.stars
    assert_equal option, approval.option
    assert_equal decision, approval.decision
    assert_equal @user, approval.decision_participant.user
  end

end