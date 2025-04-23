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
end