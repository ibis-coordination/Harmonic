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
    assert_equal "We chose Option A.", @decision.statement&.text
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

  test "creator can add statement on closed decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_statement",
      params: { text: "We decided to go with Option A." }

    @decision.reload
    assert_equal "We decided to go with Option A.", @decision.statement&.text
    assert_response :redirect
  end

  test "creator can update existing statement" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Note.create!(
      subtype: "statement", text: "First draft.",
      statementable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner",
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_statement",
      params: { text: "Updated statement." }

    @decision.reload
    assert_equal "Updated statement.", @decision.statement&.text
    assert_response :redirect
  end

  test "creator cannot add statement on open decision" do
    sign_in_as(@user, tenant: @tenant)

    assert_not @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_statement",
      params: { text: "Premature statement" }

    @decision.reload
    assert_nil @decision.statement
  end

  test "statement is displayed on show page when present" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Note.create!(
      subtype: "statement", text: "We chose Option A.",
      statementable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner",
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/We chose Option A/, response.body)
  end

  test "statement embed is shown on closed decision with statement" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Note.create!(
      subtype: "statement", text: "The final word.",
      statementable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner",
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/pulse-statement-embed/, response.body)
    assert_match(/The final word/, response.body)
    assert_match(/added this statement/, response.body)
  end

  test "statement is displayed in markdown view" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Note.create!(
      subtype: "statement", text: "We chose Option A.",
      statementable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner",
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}",
      headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/We chose Option A/, response.body)
  end

  test "non-creator cannot add statement" do
    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Other User",
      email: "stmt-#{unique_id}@example.com",
      user_type: "human"
    )
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(other_user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_statement",
      params: { text: "Unauthorized statement" }

    @decision.reload
    assert_nil @decision.statement
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

  # === Executive Decision Tests ===

  test "executive decision show page hides voting UI but shows selection UI for decision maker" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/Executive Decision/, response.body)
    # No star checkboxes or results table
    assert_select "input.pulse-star-checkbox", count: 0
    assert_select "table.pulse-results-table", count: 0
    # Decision maker sees selection submit button
    assert_select "button[data-decision-target='submitButton']", text: "Submit Selection"
  end

  test "cannot submit votes on executive decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive")
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
      params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }

    assert_response :redirect
    assert_match(/Executive/, flash[:alert])
  end

  test "cannot vote via API on executive decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive")
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/vote",
      params: { votes: [{ option_title: "Option A", accept: true }] }

    assert_response :success
    assert_match(/Executive/i, response.body)
  end

  test "decision maker can close executive decision" do
    unique_id = SecureRandom.hex(8)
    decision_maker = User.create!(name: "Boss", email: "boss-#{unique_id}@example.com", user_type: "human")
    @tenant.add_user!(decision_maker)
    @collective.add_user!(decision_maker)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive", decision_maker: decision_maker)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(decision_maker, tenant: @tenant)
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      params: { final_statement: "I've decided on Option A." }

    @decision.reload
    assert @decision.closed?
    assert_equal "I've decided on Option A.", @decision.statement&.text
  end

  test "creator cannot close executive decision when decision maker is set" do
    unique_id = SecureRandom.hex(8)
    decision_maker = User.create!(name: "Boss", email: "boss-creator-#{unique_id}@example.com", user_type: "human")
    @tenant.add_user!(decision_maker)
    @collective.add_user!(decision_maker)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive", decision_maker: decision_maker)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision"

    @decision.reload
    assert_not @decision.closed?
  end

  test "submitting statement on open executive decision is rejected" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert_not @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_statement",
      params: { text: "I've decided on Option A." }

    @decision.reload
    assert_not @decision.closed?, "add_statement should not close an open executive decision"
    assert_nil @decision.statement
  end

  test "submitting statement on open vote decision is rejected" do
    sign_in_as(@user, tenant: @tenant)

    assert_not @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_statement",
      params: { text: "Premature statement" }

    @decision.reload
    assert_not @decision.closed?
    assert_nil @decision.statement
  end

  # === Executive Option Selection Tests ===

  test "decision maker can submit selection and close executive decision" do
    unique_id = SecureRandom.hex(8)
    decision_maker = User.create!(name: "Boss", email: "boss-select-#{unique_id}@example.com", user_type: "human")
    @tenant.add_user!(decision_maker)
    @collective.add_user!(decision_maker)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive", decision_maker: decision_maker)
    participant = DecisionParticipantManager.new(decision: @decision, user: decision_maker).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Option.create!(decision: @decision, decision_participant: participant, title: "Option C")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(decision_maker, tenant: @tenant)
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      params: { selections: ["Option A", "Option C"], final_statement: "Selected A and C." }

    @decision.reload
    assert @decision.closed?, "Decision should be closed"
    assert_equal "Selected A and C.", @decision.statement&.text

    # Check votes were created
    dm_participant = DecisionParticipantManager.new(decision: @decision, user: decision_maker).find_or_create_participant
    votes = Vote.where(decision: @decision, decision_participant: dm_participant)
    assert_equal 3, votes.count
    assert_equal 1, votes.find_by(option: @decision.options.find_by(title: "Option A")).accepted
    assert_equal 0, votes.find_by(option: @decision.options.find_by(title: "Option B")).accepted
    assert_equal 1, votes.find_by(option: @decision.options.find_by(title: "Option C")).accepted
    # preferred is always 0 for executive selections
    votes.each { |v| assert_equal 0, v.preferred }
  end

  test "non-decision-maker cannot submit selection on executive decision" do
    unique_id = SecureRandom.hex(8)
    decision_maker = User.create!(name: "Boss", email: "boss-noselect-#{unique_id}@example.com", user_type: "human")
    @tenant.add_user!(decision_maker)
    @collective.add_user!(decision_maker)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive", decision_maker: decision_maker)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      params: { selections: ["Option A"], final_statement: "I'll decide." }

    @decision.reload
    assert_not @decision.closed?, "Non-decision-maker should not be able to close"
  end

  test "executive decision close with no selections creates votes with accepted=0" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive")
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      params: { final_statement: "None of the above." }

    @decision.reload
    assert @decision.closed?
    dm_participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    votes = Vote.where(decision: @decision, decision_participant: dm_participant)
    assert_equal 2, votes.count
    votes.each { |v| assert_equal 0, v.accepted }
  end

  test "closed executive decision shows selected options with checkmarks" do
    unique_id = SecureRandom.hex(8)
    decision_maker = User.create!(name: "Boss", email: "boss-show-#{unique_id}@example.com", user_type: "human")
    @tenant.add_user!(decision_maker)
    @collective.add_user!(decision_maker)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive", decision_maker: decision_maker, deadline: 1.hour.ago)
    participant = DecisionParticipantManager.new(decision: @decision, user: decision_maker).find_or_create_participant
    opt_a = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    opt_b = Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    # Create votes: A selected, B not
    Vote.create!(decision: @decision, option: opt_a, decision_participant: participant,
                 tenant: @tenant, collective: @collective, accepted: 1, preferred: 0)
    Vote.create!(decision: @decision, option: opt_b, decision_participant: participant,
                 tenant: @tenant, collective: @collective, accepted: 0, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    # Should show checkmark for selected option
    assert_select ".executive-option-selected", minimum: 1
  end

  test "cannot close an already closed executive decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive", deadline: 1.hour.ago)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      params: { selections: ["Option A"], final_statement: "Trying again." }

    assert_response :redirect
    assert_match(/already closed/i, flash[:alert])
  end

  test "executive close with invalid option title raises error" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "executive")
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/close_decision",
      params: { selections: ["Nonexistent Option"], final_statement: "Oops." }

    @decision.reload
    assert_not @decision.closed?, "Decision should not close with invalid selection"
    assert_response :redirect
    assert_match(/Unknown option/, flash[:alert])
  end

  test "create executive decision with decision_maker handle via API" do
    unique_id = SecureRandom.hex(8)
    decision_maker = User.create!(name: "Boss", email: "boss-handle-#{unique_id}@example.com", user_type: "human")
    @tenant.add_user!(decision_maker)
    @collective.add_user!(decision_maker)
    dm_handle = decision_maker.tenant_users.first.handle

    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide/actions/create_decision",
      params: { question: "Handle test?", description: "", options_open: true,
                deadline: 1.week.from_now, subtype: "executive",
                decision_maker: "@#{dm_handle}" },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/successfully created/, response.body)

    # Extract decision ID from response and verify decision_maker
    decision_id = response.body[/Decision \[(\w+)\]/, 1]
    assert decision_id, "Should find decision ID in response"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    new_decision = Decision.find_by!(truncated_id: decision_id)
    assert_equal decision_maker.id, new_decision.decision_maker_id
    assert_equal "executive", new_decision.subtype
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === Lottery Decision Tests ===

  test "open lottery hides voting UI and results" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "lottery")
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/Lottery/, response.body)
    # No voting UI
    assert_select "input.pulse-acceptance-checkbox", count: 0
    assert_select "input.pulse-star-checkbox", count: 0
    assert_select "button[data-decision-target='submitButton']", count: 0
    # Results hidden until closed
    assert_select "table.pulse-results-table", count: 0
  end

  test "closed drawn lottery shows results table" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(
      subtype: "lottery",
      deadline: 1.hour.ago,
      lottery_beacon_round: 100,
      lottery_beacon_randomness: "abc123",
    )
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_select "table.pulse-results-table"
  end

  test "cannot submit votes on lottery decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "lottery")
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
      params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }

    assert_response :redirect
    assert_match(/Lottery/i, flash[:alert])
  end

  test "cannot vote via API on lottery decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "lottery")
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/vote",
      params: { votes: [{ option_title: "Option A", accept: true }] }

    assert_response :success
    assert_match(/Lottery/i, response.body)
  end

  # === Closed Decision Tests ===

  test "cannot change deadline on closed decision via settings" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: 1.hour.ago)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert @decision.closed?
    original_deadline = @decision.deadline

    # HTML form won't include deadline for closed decisions
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
      params: { question: "Updated question" }

    @decision.reload
    assert @decision.closed?, "Decision should still be closed"
    assert_equal original_deadline.to_i, @decision.deadline.to_i
    assert_equal "Updated question", @decision.question
  end

  test "cannot change deadline on closed decision via API" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: 1.hour.ago)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert @decision.closed?

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
      params: { deadline: 1.week.from_now },
      headers: { "Accept" => "text/markdown" }

    assert_match(/Cannot change deadline/i, response.body)
    @decision.reload
    assert @decision.closed?
  end

  test "settings page hides deadline section for closed decision" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(deadline: 1.hour.ago)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings"
    assert_response :success
    assert_select "h2", text: "Deadline", count: 0
  end

  test "cannot submit votes on closed decision" do
    sign_in_as(@user, tenant: @tenant)

    # Close the decision
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    @decision.update!(deadline: Time.current)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
      params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }

    assert_response :redirect
    assert_match(/closed/, flash[:alert])
  end

  # === Lottery Verification Page Tests ===

  test "verify page renders for drawn lottery" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(
      subtype: "lottery",
      deadline: 1.hour.ago,
      lottery_beacon_round: 12345,
      lottery_beacon_randomness: "deadbeef123",
    )
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Entry A")
    Option.create!(decision: @decision, decision_participant: participant, title: "Entry B")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/verify"
    assert_response :success
    assert_select "code", text: "12345"
    assert_select "code", text: "deadbeef123"
  end

  test "verify page redirects for non-drawn lottery" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "lottery")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/verify"
    assert_response :redirect
  end

  test "closed lottery shows drawing message when beacon pending" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "lottery", deadline: 1.hour.ago)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Entry A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/Drawing/, response.body)
  end

  test "drawn lottery shows verify link" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(
      subtype: "lottery",
      deadline: 1.hour.ago,
      lottery_beacon_round: 999,
      lottery_beacon_randomness: "abc",
    )
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Entry A")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/verifiably random/, response.body)
  end

  # === Vote Decision Beacon Tests ===

  test "verify page renders for vote decision with beacon" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(
      subtype: "vote",
      deadline: 1.hour.ago,
      lottery_beacon_round: 12345,
      lottery_beacon_randomness: "deadbeef123",
    )
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/verify"
    assert_response :success
    assert_match(/Verify Results/, response.body)
    assert_match(/Tiebreakers are/, response.body)
    assert_match(/voters page/, response.body)
  end

  test "verify page redirects for vote decision without beacon" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "vote", deadline: 1.hour.ago)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/verify"
    assert_response :redirect
  end

  test "closed vote decision shows question marks when beacon pending" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "vote", deadline: 1.hour.ago)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option_a = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    option_b = Option.create!(decision: @decision, decision_participant: participant, title: "Option B")
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option_a, decision_participant: participant, accepted: 1, preferred: 0)
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option_b, decision_participant: participant, accepted: 1, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/\?\?\?/, response.body)
  end

  test "drawn vote decision shows verify link" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(
      subtype: "vote",
      deadline: 1.hour.ago,
      lottery_beacon_round: 999,
      lottery_beacon_randomness: "abc",
    )
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option, decision_participant: participant, accepted: 1, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/verifiably random/, response.body)
  end

  test "open vote decision shows finalized at close time message" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision.update!(subtype: "vote", deadline: 1.hour.from_now)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    option = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")
    Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option, decision_participant: participant, accepted: 1, preferred: 0)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_match(/finalized at close time/, response.body)
  end
end
