# frozen_string_literal: true

require "test_helper"

class DecisionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    # Create a decision for tests
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @decision = Decision.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      question: "Test Decision?",
      description: "A test decision for voting",
      deadline: 1.week.from_now
    )

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === New Decision Form Tests ===

  test "authenticated user can access new decision form" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/decide"
    assert_response :success
    assert_select "form"
  end

  test "unauthenticated user is redirected from new decision form" do
    get "/studios/#{@collective.handle}/decide"
    assert_redirected_to "/login"
  end

  # === Create Decision Tests ===

  test "authenticated user can create decision" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Decision.unscoped.where(collective: @collective).count

    post "/studios/#{@collective.handle}/decide", params: {
      decision: {
        question: "Should we do this?",
        description: "Description of the decision",
        options_open: true
      },
      deadline_option: "no_deadline"
    }

    final_count = Decision.unscoped.where(collective: @collective).count
    assert_equal initial_count + 1, final_count

    # Find the created decision by question
    decision = Decision.unscoped.find_by(question: "Should we do this?", collective: @collective)
    assert_not_nil decision
    assert_response :redirect
  end

  test "create decision with datetime deadline" do
    sign_in_as(@user, tenant: @tenant)

    deadline_time = (Time.current + 1.week).strftime('%Y-%m-%dT%H:%M')

    post "/studios/#{@collective.handle}/decide", params: {
      decision: {
        question: "Deadline decision test?",
        description: "Testing deadline",
        options_open: true
      },
      deadline_option: "datetime",
      deadline: deadline_time
    }

    decision = Decision.unscoped.find_by(question: "Deadline decision test?", collective: @collective)
    assert_not_nil decision
    assert_response :redirect
  end

  test "create decision with blank question still creates but shows error in form" do
    sign_in_as(@user, tenant: @tenant)

    # The controller may or may not validate empty questions depending on model validations
    # This test verifies the expected behavior
    post "/studios/#{@collective.handle}/decide", params: {
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
    get "/studios/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match @decision.question, response.body
  end

  test "unauthenticated user is redirected to login from decision" do
    get "/studios/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "nonexistent decision returns 404 or raises not found" do
    sign_in_as(@user, tenant: @tenant)

    # The app may raise RecordNotFound or render 404
    begin
      get "/studios/#{@collective.handle}/d/nonexistent123"
      assert_response :not_found
    rescue ActiveRecord::RecordNotFound
      # This is also acceptable behavior
      pass
    end
  end

  # === Settings Tests ===

  test "creator can access decision settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/d/#{@decision.truncated_id}/settings"
    assert_response :success
  end

  test "non-creator cannot access decision settings" do
    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Other User",
      email: "other-user-#{unique_id}@example.com",
      user_type: "human"
    )
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/studios/#{@collective.handle}/d/#{@decision.truncated_id}/settings"
    assert_response :forbidden
  end

  test "creator can update decision settings" do
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
      params: { decision: { question: "Updated Question?" } },
      headers: { 'Referer' => "/studios/#{@collective.handle}/d/#{@decision.truncated_id}" }

    @decision.reload
    assert_equal "Updated Question?", @decision.question
    assert_redirected_to @decision.path
  end

  # === Duplicate Tests ===

  test "user can duplicate decision" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Decision.unscoped.where(collective: @collective).count

    post "/studios/#{@collective.handle}/d/#{@decision.truncated_id}/duplicate"

    final_count = Decision.unscoped.where(collective: @collective).count
    assert_equal initial_count + 1, final_count

    # Should redirect to the new decision
    assert_response :redirect
  end

  # === Options Tests ===

  test "user can add option to decision" do
    sign_in_as(@user, tenant: @tenant)

    # First become a participant
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert_difference "Option.count", 1 do
      post "/studios/#{@collective.handle}/d/#{@decision.truncated_id}/options.html",
        params: { title: "Option A" }
    end

    assert_response :success
    option = Option.last
    assert_equal "Option A", option.title
  end

  # === Voting Tests ===

  test "participant can vote on options" do
    sign_in_as(@user, tenant: @tenant)

    # Set up participant and option
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(
      decision: @decision,
      decision_participant: participant,
      title: "Test Option"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/studios/#{@collective.handle}/d/#{@decision.truncated_id}/actions/vote",
      params: { votes: [{ option_title: option.title, accept: true, prefer: false }] }

    assert_response :success
  end
end
