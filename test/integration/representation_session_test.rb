require "test_helper"

class RepresentationSessionIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ====================
  # Starting Representation
  # ====================

  test "user with representative role can start representation" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }

    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_equal '/representing', path
  end

  test "user without representative role cannot start representation" do
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }

    assert_response :forbidden
  end

  test "user with any_member_can_represent setting can start representation" do
    @superagent.settings['any_member_can_represent'] = true
    @superagent.save!
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "must confirm understanding to start representation" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # First load the represent page
    get "/studios/#{@superagent.handle}/represent"
    assert_response :success

    # Try without confirming understanding
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'false' },
         headers: { "HTTP_REFERER" => "/studios/#{@superagent.handle}/represent" }

    assert_response :redirect
    follow_redirect!
    assert_match /You must check the box/, flash[:alert]
  end

  test "cannot start representation if already in active session" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start first session
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Try to start second session
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' },
         headers: { "HTTP_REFERER" => "/studios/#{@superagent.handle}/represent" }

    assert_response :redirect
    follow_redirect!
    assert_match /Nested representation sessions are not allowed/, flash[:alert]
  end

  test "representation session is created when starting" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    assert_difference 'RepresentationSession.count', 1 do
      post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    end

    session = RepresentationSession.last
    assert_equal @user, session.representative_user
    # effective_user is the superagent's trustee for studio representation
    assert_equal @superagent.trustee_user, session.effective_user
    assert_equal @superagent, session.superagent
    assert session.active?
  end

  # ====================
  # Actions While Representing
  # ====================

  test "creating note while representing attributes it to trustee user" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Create a note while representing
    post "/studios/#{@superagent.handle}/note", params: {
      note: {
        title: "Note from representation",
        text: "This should be attributed to the trustee user",
      },
    }

    note = Note.last
    assert_equal @superagent.trustee_user.id, note.created_by_id
    assert_not_equal @user.id, note.created_by_id
  end

  test "activity is recorded in representation session" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Create a note while representing
    post "/studios/#{@superagent.handle}/note", params: {
      note: {
        title: "Note for activity log",
        text: "This should be recorded in the session",
      },
    }

    session = RepresentationSession.last
    # The activity log should contain the note creation
    assert session.activity_log['activity'].count > 0
    assert session.action_count > 0
  end

  # ====================
  # Stopping Representation
  # ====================

  test "representative can stop their session" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    session = RepresentationSession.unscoped.where(superagent_id: @superagent.id).last
    assert_not_nil session, "RepresentationSession should have been created"
    assert_nil session.ended_at

    # Stop representation
    delete "/studios/#{@superagent.handle}/represent"

    assert_response :redirect
    session.reload
    assert session.ended?
    assert session.ended_at.present?
  end

  test "after stopping representation current_user returns original user" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Create note while representing - should be trustee
    post "/studios/#{@superagent.handle}/note", params: {
      note: { title: "During representation", text: "Trustee note" },
    }
    note_during = Note.last
    assert_equal @superagent.trustee_user.id, note_during.created_by_id

    # Stop representation
    delete "/studios/#{@superagent.handle}/represent"
    follow_redirect!

    # Create note after stopping - should be user
    post "/studios/#{@superagent.handle}/note", params: {
      note: { title: "After representation", text: "User note" },
    }
    note_after = Note.last
    assert_equal @user.id, note_after.created_by_id
  end

  # ====================
  # Viewing Representation Sessions
  # ====================

  test "representation session show page is accessible" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    session.end!
    sign_in_as(@user, tenant: @tenant)

    get "/studios/#{@superagent.handle}/r/#{session.truncated_id}"

    assert_response :success
  end

  test "representation index shows sessions and representatives" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    session.end!
    sign_in_as(@user, tenant: @tenant)

    get "/studios/#{@superagent.handle}/representation"

    assert_response :success
  end

  # ====================
  # Edge Cases
  # ====================

  test "if representative role is removed during session it ends gracefully" do
    superagent_member = @superagent.superagent_members.find_by(user: @user)
    superagent_member.add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Remove representative role
    superagent_member.remove_role!('representative')

    # Access a page - should end representation gracefully
    get "/studios/#{@superagent.handle}"

    assert_response :success
    # Session should have been cleared since user can no longer represent
  end

  test "representation session expires after 24 hours" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
      began_at: 25.hours.ago,
    )

    assert session.expired?
    # Note: active? only checks ended_at, not expired?
    # But expired? does check if the session has exceeded 24 hours
  end

  test "non-member is redirected to join page" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)

    get "/studios/#{@superagent.handle}/represent"

    # Non-members are redirected to join the studio
    assert_response :redirect
    assert_match /join/, response.location
  end

  test "unauthenticated user cannot start representation" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')

    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }

    assert_response :redirect
  end

  test "representation persists across multiple requests" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@superagent.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # The /representing page should work
    get "/representing"
    assert_response :success

    # Access today's cycle
    get "/studios/#{@superagent.handle}/cycles/today"
    assert_response :success

    # Create content - should still be attributed to trustee
    post "/studios/#{@superagent.handle}/note", params: {
      note: { title: "Third request note", text: "Still representing" },
    }

    note = Note.last
    assert_equal @superagent.trustee_user.id, note.created_by_id
  end
end
