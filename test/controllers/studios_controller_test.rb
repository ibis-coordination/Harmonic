require "test_helper"

class StudiosControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    # Make user an admin of the superagent
    superagent_member = @superagent.superagent_members.find_by(user: @user)
    superagent_member.add_role!('admin') if superagent_member
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def create_test_superagent(name: "Test Studio", handle: "test-superagent-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    superagent = Superagent.create!(
      tenant: @tenant,
      created_by: @user,
      name: name,
      handle: handle
    )
    superagent.add_user!(@user)
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope
    superagent
  end

  # === Unauthenticated Access Tests ===

  test "unauthenticated user is redirected from superagent homepage" do
    get "/studios/#{@superagent.handle}"
    assert_response :redirect
  end

  test "unauthenticated user is redirected from new superagent form" do
    get "/studios/new"
    assert_response :redirect
  end

  # === Show Studio Tests ===

  test "authenticated user can view superagent homepage" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@superagent.handle}"
    assert_response :success
  end

  # === New Studio Tests ===

  test "authenticated user can access new superagent form" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/new"
    assert_response :success
  end

  # === Create Studio Tests ===

  test "authenticated user can create a superagent" do
    sign_in_as(@user, tenant: @tenant)
    unique_handle = "new-studio-#{SecureRandom.hex(4)}"

    assert_difference "Superagent.count", 1 do
      post "/studios", params: {
        name: "New Studio",
        handle: unique_handle,
        description: "A new studio"
      }
    end

    superagent = Superagent.find_by(handle: unique_handle)
    assert_not_nil superagent
    assert_equal "New Studio", superagent.name
    assert_equal @user, superagent.created_by
    assert_response :redirect
  end

  # === Settings Tests ===

  test "superagent admin can access settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@superagent.handle}/settings"
    assert_response :success
  end

  test "non-admin cannot access superagent settings" do
    other_user = create_user(name: "Regular User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    # Don't add admin role

    sign_in_as(other_user, tenant: @tenant)
    get "/studios/#{@superagent.handle}/settings"
    # Should show an error message (rendered with 200)
    assert_response :success
    assert_match /admin/i, response.body
  end

  # === Update Settings Tests ===

  test "superagent admin can update settings" do
    sign_in_as(@user, tenant: @tenant)
    # Settings update uses POST, redirects to referrer so we need to set that header
    post "/studios/#{@superagent.handle}/settings",
      params: {
        name: "Updated Studio Name",
        description: "Updated description",
        timezone: "America/New_York",
        tempo: "weekly"
      },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@superagent.handle}/settings" }

    @superagent.reload
    assert_equal "Updated Studio Name", @superagent.name
    assert_equal "Updated description", @superagent.description
    assert_response :redirect
  end

  test "non-admin cannot update superagent settings" do
    other_user = create_user(name: "Regular User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)

    original_name = @superagent.name

    sign_in_as(other_user, tenant: @tenant)
    post "/studios/#{@superagent.handle}/settings",
      params: { name: "Hacked Name" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@superagent.handle}/settings" }

    @superagent.reload
    assert_equal original_name, @superagent.name
    assert_response :forbidden
  end

  # === Members Tests ===

  test "authenticated user can view superagent members" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@superagent.handle}/members"
    assert_response :success
  end

  # === Invite Tests ===

  test "admin can access invite page" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@superagent.handle}/invite"
    assert_response :success
  end

  test "invite page has copy button separate from link box" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@superagent.handle}/invite"
    assert_response :success

    # Verify the invite link is in its own box
    assert_select ".pulse-invite-link-box" do
      assert_select "code.pulse-invite-link"
    end

    # Verify the copy button is in a separate actions section
    assert_select ".pulse-invite-actions" do
      assert_select "button.pulse-copy-btn.pulse-action-btn-secondary"
    end
  end

  # === Handle Available Tests ===

  test "handle_available returns true for available handle" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/available", params: { handle: "completely-new-handle-#{SecureRandom.hex(8)}" }
    assert_response :success

    json = JSON.parse(response.body)
    assert json["available"]
  end

  test "handle_available returns false for taken handle" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/available", params: { handle: @superagent.handle }
    assert_response :success

    json = JSON.parse(response.body)
    assert_not json["available"]
  end

  # === Join Studio Tests ===

  test "user can view join page with valid invite code" do
    # Create a new superagent for this test to avoid member conflicts
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    test_superagent = Superagent.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Join Test Studio",
      handle: "join-test-#{SecureRandom.hex(4)}"
    )
    test_superagent.add_user!(@user)
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    invite = test_superagent.find_or_create_shareable_invite(@user)

    # Create a new user who is NOT a member of test_superagent
    new_user = create_user(name: "New Member")
    @tenant.add_user!(new_user)
    # Don't add to test_superagent

    sign_in_as(new_user, tenant: @tenant)
    get "/studios/#{test_superagent.handle}/join", params: { code: invite.code }
    assert_response :success
  end

  # === Scene Tests ===

  test "scene type superagent uses scenes route" do
    # Create the scene before signing in
    scene_handle = "test-scene-#{SecureRandom.hex(4)}"
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    scene = Superagent.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Test Scene",
      handle: scene_handle,
      superagent_type: "scene"
    )
    scene.add_user!(@user)
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/scenes/#{scene_handle}"
    assert_response :success
  end
end
