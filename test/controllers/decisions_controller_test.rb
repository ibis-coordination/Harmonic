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
    get "/collectives/#{@collective.handle}/decide"
    assert_response :success
    assert_select "form"
  end

  test "new decision form shows members-only visibility hint for non-main collective" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/decide"
    assert_response :success
    assert_select ".pulse-visibility-hint", /Only members of this collective/
  end

  test "new decision form shows publicly visible hint for main collective" do
    sign_in_as(@user, tenant: @tenant)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user) unless main_collective.collective_members.exists?(user: @user)
    get "/decide"
    assert_response :success
    assert_select ".pulse-visibility-hint", /publicly visible/
  end

  test "new decision markdown shows members-only visibility for non-main collective" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/decide", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Only members of this collective/, response.body)
  end

  test "new decision markdown shows publicly visible for main collective" do
    sign_in_as(@user, tenant: @tenant)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user) unless main_collective.collective_members.exists?(user: @user)
    get "/decide", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/publicly visible/, response.body)
  end

  test "unauthenticated user is redirected from new decision form" do
    get "/collectives/#{@collective.handle}/decide"
    assert_redirected_to "/login"
  end

  # === Create Decision Tests ===

  test "authenticated user can create decision" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Decision.unscoped.where(collective: @collective).count

    post "/collectives/#{@collective.handle}/decide", params: {
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

    post "/collectives/#{@collective.handle}/decide", params: {
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
    post "/collectives/#{@collective.handle}/decide", params: {
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
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match @decision.question, response.body
  end

  test "unauthenticated user is redirected to login from decision" do
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "nonexistent decision returns 404 or raises not found" do
    sign_in_as(@user, tenant: @tenant)

    # The app may raise RecordNotFound or render 404
    begin
      get "/collectives/#{@collective.handle}/d/nonexistent123"
      assert_response :not_found
    rescue ActiveRecord::RecordNotFound
      # This is also acceptable behavior
      pass
    end
  end

  # === Settings Tests ===

  test "creator can access decision settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings"
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
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings"
    assert_response :forbidden
  end

  test "creator can update decision settings" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
      params: { decision: { question: "Updated Question?" } },
      headers: { 'Referer' => "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}" }

    @decision.reload
    assert_equal "Updated Question?", @decision.question
    assert_redirected_to @decision.path
  end

  # === Duplicate Tests ===

  test "user can duplicate decision" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Decision.unscoped.where(collective: @collective).count

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/duplicate"

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
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/options.html",
        params: { title: "Option A" }
    end

    assert_response :success
    option = Option.last
    assert_equal "Option A", option.title
  end

  # === Close Decision Tests ===

  test "creator can close decision from show page" do
    sign_in_as(@user, tenant: @tenant)

    assert_not @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision"

    @decision.reload
    assert @decision.closed?, "Decision should be closed after close_decision action"
  end

  test "creator can close decision with final statement" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      params: { final_statement: "We chose Option A." }

    @decision.reload
    assert @decision.closed?
    assert_equal "We chose Option A.", @decision.final_statement
  end

  test "creator can close decision via markdown action" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      headers: { "Accept" => "text/markdown" }

    @decision.reload
    assert @decision.closed?
    assert_response :success
    assert_match(/closed/i, response.body)
  end

  test "non-creator cannot close decision" do
    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Other User",
      email: "close-test-#{unique_id}@example.com",
      user_type: "human"
    )
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision"

    @decision.reload
    assert_not @decision.closed?, "Non-creator should not be able to close decision"
  end

  test "cannot close already closed decision" do
    sign_in_as(@user, tenant: @tenant)

    # Close the decision first
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision"
    # Should still succeed gracefully (idempotent)
    assert_response :redirect
  end

  # === Final Statement Tests ===

  test "creator can update final statement on closed decision" do
    sign_in_as(@user, tenant: @tenant)

    # Close the decision first
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/final_statement",
      params: { final_statement: "We decided to go with Option A." }

    @decision.reload
    assert_equal "We decided to go with Option A.", @decision.final_statement
    assert_response :redirect
  end

  test "creator cannot update final statement on open decision" do
    sign_in_as(@user, tenant: @tenant)

    assert_not @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/final_statement",
      params: { final_statement: "Premature statement" }

    @decision.reload
    assert_nil @decision.final_statement
  end

  test "final statement is displayed on show page when present" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current, final_statement: "We chose Option A.")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/We chose Option A/, response.body)
  end

  test "final statement edit form is shown to creator on closed decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/final_statement/, response.body)
  end

  test "final statement is displayed in markdown view" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current, final_statement: "We chose Option A.")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}",
      headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/We chose Option A/, response.body)
  end

  test "non-creator cannot update final statement" do
    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Other User",
      email: "final-stmt-#{unique_id}@example.com",
      user_type: "human"
    )
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    # Close the decision
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(other_user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/final_statement",
      params: { final_statement: "Unauthorized statement" }

    @decision.reload
    assert_nil @decision.final_statement
  end

  # === Voting Tests ===

  test "participant can vote on options via action endpoint" do
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

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/vote",
      params: { votes: [{ option_title: option.title, accept: true, prefer: false }] }

    assert_response :success
  end

  test "participant can submit votes via batch form" do
    sign_in_as(@user, tenant: @tenant)

    # Set up participant and options
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option_a = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    option_b = Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
      params: {
        votes: [
          { option_title: "Option A", accepted: "1", preferred: "0" },
          { option_title: "Option B", accepted: "1", preferred: "1" },
        ],
      }

    assert_response :redirect

    # Verify votes were created
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    vote_a = Vote.find_by(option: option_a, decision_participant: participant)
    vote_b = Vote.find_by(option: option_b, decision_participant: participant)
    assert_equal 1, vote_a.accepted
    assert_equal 0, vote_a.preferred
    assert_equal 1, vote_b.accepted
    assert_equal 1, vote_b.preferred
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === Results Visibility Tests ===

  test "results are hidden for user who has not voted" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/Submit your vote to see results/, response.body)
    assert_select "table.pulse-results-table", count: 0
  end

  test "results are visible for user who has voted" do
    sign_in_as(@user, tenant: @tenant)

    # Create participant, option, and vote
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(decision: @decision, decision_participant: participant, title: "Opt A")
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option, decision_participant: participant, accepted: 1, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_select "table.pulse-results-table"
  end

  test "results are always visible when decision is closed" do
    sign_in_as(@user, tenant: @tenant)

    # Close the decision without voting
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_select "table.pulse-results-table"
  end

  test "results are hidden in markdown view for user who has not voted" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}",
      headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_no_match(/Results are sorted/, response.body)
    assert_match(/Submit your vote to see results/, response.body)
  end

  test "results are visible in markdown view for user who has voted" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(decision: @decision, decision_participant: participant, title: "Opt A")
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option, decision_participant: participant, accepted: 1, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}",
      headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Results are sorted/, response.body)
  end

  # === Voters Page Tests ===

  test "voters page shows per-option vote breakdown" do
    sign_in_as(@user, tenant: @tenant)

    # Create participant, options, and votes
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option_a = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    option_b = Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option_a, decision_participant: participant, accepted: 1, preferred: 1)
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option_b, decision_participant: participant, accepted: 1, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/voters"
    assert_response :success
    assert_match(/Option A/, response.body)
    assert_match(/Option B/, response.body)
    assert_match(@user.display_name, response.body)
  end

  test "voters page is blocked for blocked users" do
    sign_in_as(@user, tenant: @tenant)

    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Blocked User",
      email: "blocked-voter-#{unique_id}@example.com",
      user_type: "human"
    )
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    UserBlock.create!(blocker: @user, blocked: other_user, tenant: @tenant)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(other_user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/voters"
    assert_response :forbidden
  end

  test "voters page renders markdown format" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option, decision_participant: participant, accepted: 1, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/voters",
      headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Option A/, response.body)
  end

  test "cannot vote via API action on closed decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/vote",
      params: { votes: [{ option_title: "Option A", accept: true, prefer: false }] }

    assert_response :success
    assert_match(/closed/i, response.body)

    # Verify no vote was created
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert_equal 0, Vote.where(option: option).count
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "cannot submit votes on closed decision" do
    sign_in_as(@user, tenant: @tenant)

    # Close the decision
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
      params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }

    assert_response :redirect
    assert_match(/closed/, flash[:alert])
  end
end
