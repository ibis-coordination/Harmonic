# frozen_string_literal: true

require "test_helper"

class CommitmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    # Create a commitment for tests
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @commitment = Commitment.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Commitment",
      description: "A test commitment",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === New Commitment Form Tests ===

  test "authenticated user can access new commitment form" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/commit"
    assert_response :success
    assert_select "form"
  end

  test "new commitment form shows members-only visibility hint for non-main collective" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/commit"
    assert_response :success
    assert_select ".pulse-visibility-hint", /Only members of this collective/
  end

  test "new commitment form shows publicly visible hint for main collective" do
    sign_in_as(@user, tenant: @tenant)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user) unless main_collective.collective_members.exists?(user: @user)
    get "/commit"
    assert_response :success
    assert_select ".pulse-visibility-hint", /publicly visible/
  end

  test "new commitment markdown shows members-only visibility for non-main collective" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/commit", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Only members of this collective/, response.body)
  end

  test "new commitment markdown shows publicly visible for main collective" do
    sign_in_as(@user, tenant: @tenant)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user) unless main_collective.collective_members.exists?(user: @user)
    get "/commit", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/publicly visible/, response.body)
  end

  test "unauthenticated user is redirected from new commitment form" do
    get "/collectives/#{@collective.handle}/commit"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  # === Create Commitment Tests ===

  test "authenticated user can create commitment" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Commitment.unscoped.where(collective: @collective).count

    post "/collectives/#{@collective.handle}/commit", params: {
      commitment: {
        title: "New Test Commitment",
        description: "Testing commitment creation",
        critical_mass: 10,
      },
      deadline_option: "no_deadline",
    }

    final_count = Commitment.unscoped.where(collective: @collective).count
    assert_equal initial_count + 1, final_count

    commitment = Commitment.unscoped.find_by(title: "New Test Commitment", collective: @collective)
    assert_not_nil commitment
    assert_response :redirect
  end

  test "create commitment with close at critical mass deadline" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/commit", params: {
      commitment: {
        title: "Critical Mass Commitment",
        description: "Testing critical mass",
        critical_mass: 5,
      },
      deadline_option: "close_at_critical_mass",
    }

    commitment = Commitment.unscoped.find_by(title: "Critical Mass Commitment", collective: @collective)
    assert_not_nil commitment
    assert_response :redirect
  end

  # === Show Commitment Tests ===

  test "authenticated user can view commitment" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}"
    assert_response :success
    assert_match @commitment.title, response.body
  end

  test "unauthenticated user is redirected to login from commitment" do
    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  # === Settings Tests ===

  test "creator can access commitment settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/settings"
    assert_response :success
  end

  test "non-creator cannot access commitment settings" do
    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Other User",
      email: "other-commitment-user-#{unique_id}@example.com",
      user_type: "human"
    )
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/settings"
    assert_response :forbidden
  end

  test "creator can update commitment settings" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/settings",
         params: { commitment: { title: "Updated Commitment Title" } },
         headers: { "Referer" => "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}" }

    @commitment.reload
    assert_equal "Updated Commitment Title", @commitment.title
    assert_redirected_to @commitment.path
  end

  # === Join Tests ===

  test "user can join commitment" do
    sign_in_as(@user, tenant: @tenant)

    initial_participant_count = CommitmentParticipant.unscoped.where(commitment: @commitment).count

    post "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/join.html",
         params: { name: "Test Participant" }

    # User becomes a participant
    assert_response :success

    final_participant_count = CommitmentParticipant.unscoped.where(commitment: @commitment).count
    # Should have same or more participants (might already be a participant)
    assert final_participant_count >= initial_participant_count
  end

  # === Subtype Tests ===

  test "create policy commitment with critical_mass and deadline" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/commit", params: {
      commitment: {
        title: "Be kind to each other",
        description: "Treat fellow members with respect.",
        subtype: "policy",
        critical_mass: 3,
      },
      deadline_option: "no_deadline",
    }

    commitment = Commitment.unscoped.find_by(title: "Be kind to each other", collective: @collective)
    assert_not_nil commitment, "Expected commitment to be created. Flash: #{flash.inspect}"
    assert_equal "policy", commitment.subtype
    assert_equal 3, commitment.critical_mass
    assert_not_nil commitment.deadline
    assert_response :redirect
  end

  # Regression: the commitment new.html.erb uses `form_with(url:)` (no model),
  # so its fields serialize at the top level — not under `commitment[...]`.
  # Tests that post fully-namespaced params don't exercise this path. These
  # tests post params shaped like the real form does to catch shape drift.

  test "create commitment with form-shaped params (top-level fields)" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/commit", params: {
      title: "Action from real form",
      description: "Posted top-level like form_with(url:) does.",
      critical_mass: 3,
      subtype: "action",
      deadline_option: "no_deadline",
    }

    commitment = Commitment.unscoped.find_by(title: "Action from real form", collective: @collective)
    assert_not_nil commitment, "Expected commitment to be created. Flash: #{flash.inspect}"
    assert_equal "action", commitment.subtype
    assert_response :redirect
  end

  test "create policy commitment with form-shaped params" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/commit", params: {
      title: "Form-shaped policy",
      description: "Top-level fields.",
      critical_mass: 3,
      subtype: "policy",
      deadline_option: "no_deadline",
    }

    commitment = Commitment.unscoped.find_by(title: "Form-shaped policy", collective: @collective)
    assert_not_nil commitment, "Expected policy commitment to be created. Flash: #{flash.inspect}"
    assert_equal "policy", commitment.subtype
    assert_equal 3, commitment.critical_mass
    assert_response :redirect
  end

  test "create calendar event commitment with form-shaped params" do
    sign_in_as(@user, tenant: @tenant)

    starts = 1.week.from_now.change(min: 0, sec: 0)
    ends = starts + 1.hour

    post "/collectives/#{@collective.handle}/commit", params: {
      title: "Form-shaped event",
      description: "Top-level fields.",
      subtype: "calendar_event",
      critical_mass: 1,
      starts_at: starts.strftime("%Y-%m-%dT%H:%M"),
      ends_at: ends.strftime("%Y-%m-%dT%H:%M"),
      location: "Room B",
      deadline_option: "no_deadline",
    }

    commitment = Commitment.unscoped.find_by(title: "Form-shaped event", collective: @collective)
    assert_not_nil commitment, "Expected event commitment to be created. Flash: #{flash.inspect}"
    assert_equal "calendar_event", commitment.subtype
    assert_equal "Room B", commitment.location
    assert_response :redirect
  end

  test "new commitment form respects subtype query param" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/commit?subtype=policy"
    assert_response :success
    assert_select "[data-commitment-subtype-target='policyBtn']"
  end

  # The rescue branch in #create re-renders :new on validation failure. It
  # must set all the instance variables `new` sets so the form renders
  # without raising — and must preserve the user's selected subtype.
  test "create rescue path re-renders form with subtype preserved" do
    sign_in_as(@user, tenant: @tenant)

    # Missing critical_mass triggers a validation error
    post "/collectives/#{@collective.handle}/commit", params: {
      title: "Will fail",
      description: "no critical mass",
      subtype: "calendar_event",
      deadline_option: "no_deadline",
    }

    assert_response :success # render :new returns 200, not redirect
    assert_match(/There was an error creating the commitment/, flash.now[:alert] || response.body)
    # Calendar Event button should still be the active one
    assert_select "button.pulse-action-btn[data-commitment-subtype-target='calendarEventBtn']"
    assert_select "input[name='subtype'][value='calendar_event']"
  end

  # The form uses form_with(url:) — fields serialize at the top level, NOT
  # under commitment[...]. Mixing the two (e.g. `name="commitment[subtype]"`
  # alongside `name="title"`) makes `model_params` return only the namespaced
  # subset and silently drops the rest. This asserts the field-name shape
  # so a future change can't reintroduce that bug without failing here.
  test "new commitment form serializes fields at the top level" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/commit?subtype=calendar_event"
    assert_response :success

    assert_select "input[name='title']"
    assert_select "input[name='subtype']"
    assert_select "input[name='starts_at']"
    assert_select "input[name='ends_at']"
    assert_select "input[name='location']"
    # Nothing in the form should namespace under commitment[...]
    assert_select "[name^='commitment[']", false,
      "form_with(url:) fields must be top-level — found a 'commitment[...]' field"
  end

  test "create calendar event commitment with starts_at, ends_at, location" do
    sign_in_as(@user, tenant: @tenant)

    starts = 1.week.from_now.change(min: 0, sec: 0)
    ends = starts + 1.hour

    post "/collectives/#{@collective.handle}/commit", params: {
      commitment: {
        title: "Team meeting",
        description: "Weekly sync.",
        subtype: "calendar_event",
        critical_mass: 1,
        starts_at: starts.strftime("%Y-%m-%dT%H:%M"),
        ends_at: ends.strftime("%Y-%m-%dT%H:%M"),
        location: "Conference Room A",
      },
      deadline_option: "no_deadline",
    }

    commitment = Commitment.unscoped.find_by(title: "Team meeting", collective: @collective)
    assert_not_nil commitment, "Expected commitment to be created. Flash: #{flash.inspect}"
    assert_equal "calendar_event", commitment.subtype
    assert commitment.starts_at.present?
    assert commitment.ends_at.present?
    assert_equal "Conference Room A", commitment.location
    assert_response :redirect
  end

  # === Status Partial Tests ===

  test "can get commitment status partial" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/status.html"
    assert_response :success
  end

  # === Participants Partial Tests ===

  test "can get participants list partial" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/participants.html", params: { limit: 10 }
    assert_response :success
  end
end
