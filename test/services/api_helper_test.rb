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

  test "ApiHelper.create_note raises error when not implemented" do
    api_helper = ApiHelper.new(
      current_user: @user,
      current_studio: @studio,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Note,
      current_resource: nil,
      params: {},
      request: {}
    )
    assert_raises(NotImplementedError) { api_helper.create_note }
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
end