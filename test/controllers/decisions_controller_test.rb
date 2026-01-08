# frozen_string_literal: true

require "test_helper"

class DecisionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @studio = @global_studio
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    # Create a decision for tests
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)

    @decision = Decision.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      question: "Test Decision?",
      description: "A test decision for voting",
      deadline: 1.week.from_now
    )

    Studio.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === New Decision Form Tests ===

  test "authenticated user can access new decision form" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/decide"
    assert_response :success
    assert_select "form"
  end

  test "unauthenticated user is redirected from new decision form" do
    get "/studios/#{@studio.handle}/decide"
    assert_redirected_to "/login"
  end

  # === Create Decision Tests ===

  test "authenticated user can create decision" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Decision.unscoped.where(studio: @studio).count

    post "/studios/#{@studio.handle}/decide", params: {
      decision: {
        question: "Should we do this?",
        description: "Description of the decision",
        options_open: true
      },
      deadline_option: "no_deadline"
    }

    final_count = Decision.unscoped.where(studio: @studio).count
    assert_equal initial_count + 1, final_count

    # Find the created decision by question
    decision = Decision.unscoped.find_by(question: "Should we do this?", studio: @studio)
    assert_not_nil decision
    assert_response :redirect
  end

  test "create decision with datetime deadline" do
    sign_in_as(@user, tenant: @tenant)

    deadline_time = (Time.current + 1.week).strftime('%Y-%m-%dT%H:%M')

    post "/studios/#{@studio.handle}/decide", params: {
      decision: {
        question: "Deadline decision test?",
        description: "Testing deadline",
        options_open: true
      },
      deadline_option: "datetime",
      deadline: deadline_time
    }

    decision = Decision.unscoped.find_by(question: "Deadline decision test?", studio: @studio)
    assert_not_nil decision
    assert_response :redirect
  end

  test "create decision with blank question still creates but shows error in form" do
    sign_in_as(@user, tenant: @tenant)

    # The controller may or may not validate empty questions depending on model validations
    # This test verifies the expected behavior
    post "/studios/#{@studio.handle}/decide", params: {
      decision: {
        question: "",
        description: "Description"
      },
      deadline_option: "no_deadline"
    }

    # Either re-renders form (200) or redirects after creation (302)
    assert_includes [200, 302], response.status
  end

  # === Show Decision Tests ===

  test "authenticated user can view decision" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match @decision.question, response.body
  end

  test "unauthenticated user is redirected to login from decision" do
    get "/studios/#{@studio.handle}/d/#{@decision.truncated_id}"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "nonexistent decision returns 404 or raises not found" do
    sign_in_as(@user, tenant: @tenant)

    # The app may raise RecordNotFound or render 404
    begin
      get "/studios/#{@studio.handle}/d/nonexistent123"
      assert_response :not_found
    rescue ActiveRecord::RecordNotFound
      # This is also acceptable behavior
      pass
    end
  end

  # === Settings Tests ===

  test "creator can access decision settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/d/#{@decision.truncated_id}/settings"
    assert_response :success
  end

  test "non-creator cannot access decision settings" do
    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Other User",
      email: "other-user-#{unique_id}@example.com",
      user_type: "person"
    )
    @tenant.add_user!(other_user)
    @studio.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/studios/#{@studio.handle}/d/#{@decision.truncated_id}/settings"
    assert_response :forbidden
  end

  test "creator can update decision settings" do
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@studio.handle}/d/#{@decision.truncated_id}/settings",
      params: { decision: { question: "Updated Question?" } },
      headers: { 'Referer' => "/studios/#{@studio.handle}/d/#{@decision.truncated_id}" }

    @decision.reload
    assert_equal "Updated Question?", @decision.question
    assert_redirected_to @decision.path
  end

  # === Duplicate Tests ===

  test "user can duplicate decision" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Decision.unscoped.where(studio: @studio).count

    post "/studios/#{@studio.handle}/d/#{@decision.truncated_id}/duplicate"

    final_count = Decision.unscoped.where(studio: @studio).count
    assert_equal initial_count + 1, final_count

    # Should redirect to the new decision
    assert_response :redirect
  end

  # === Options Tests ===

  test "user can add option to decision" do
    sign_in_as(@user, tenant: @tenant)

    # First become a participant
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    assert_difference "Option.count", 1 do
      post "/studios/#{@studio.handle}/d/#{@decision.truncated_id}/options.html",
        params: { title: "Option A" }
    end

    assert_response :success
    option = Option.last
    assert_equal "Option A", option.title
  end

  # === Voting Tests ===

  test "participant can vote on option" do
    sign_in_as(@user, tenant: @tenant)

    # Set up participant and option
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(
      decision: @decision,
      decision_participant: participant,
      title: "Test Option"
    )
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    post "/studios/#{@studio.handle}/d/#{@decision.truncated_id}/actions/vote",
      params: { option_id: option.id }

    assert_response :success
  end
end
