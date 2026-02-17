require "test_helper"

class StudiosControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    # Make user an admin of the collective
    collective_member = @collective.collective_members.find_by(user: @user)
    collective_member.add_role!('admin') if collective_member
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def create_test_collective(name: "Test Studio", handle: "test-collective-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: name,
      handle: handle
    )
    collective.add_user!(@user)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    collective
  end

  # === Unauthenticated Access Tests ===

  test "unauthenticated user is redirected from collective homepage" do
    get "/studios/#{@collective.handle}"
    assert_response :redirect
  end

  test "unauthenticated user is redirected from new collective form" do
    get "/studios/new"
    assert_response :redirect
  end

  # === Show Studio Tests ===

  test "authenticated user can view collective homepage" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}"
    assert_response :success
  end

  # === New Studio Tests ===

  test "authenticated user can access new collective form" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/new"
    assert_response :success
  end

  # === Create Studio Tests ===

  test "authenticated user can create a collective" do
    sign_in_as(@user, tenant: @tenant)
    unique_handle = "new-studio-#{SecureRandom.hex(4)}"

    assert_difference "Collective.count", 1 do
      post "/studios", params: {
        name: "New Studio",
        handle: unique_handle,
        description: "A new studio"
      }
    end

    collective = Collective.find_by(handle: unique_handle)
    assert_not_nil collective
    assert_equal "New Studio", collective.name
    assert_equal @user, collective.created_by
    assert_response :redirect
  end

  # === Settings Tests ===

  test "collective admin can access settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/settings"
    assert_response :success
  end

  test "non-admin cannot access collective settings" do
    other_user = create_user(name: "Regular User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    # Don't add admin role

    sign_in_as(other_user, tenant: @tenant)
    get "/studios/#{@collective.handle}/settings"
    # Should show an error message (rendered with 200)
    assert_response :success
    assert_match /admin/i, response.body
  end

  # === Update Settings Tests ===

  test "collective admin can update settings" do
    sign_in_as(@user, tenant: @tenant)
    # Settings update uses POST, redirects to referrer so we need to set that header
    post "/studios/#{@collective.handle}/settings",
      params: {
        name: "Updated Studio Name",
        description: "Updated description",
        timezone: "America/New_York",
        tempo: "weekly"
      },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/settings" }

    @collective.reload
    assert_equal "Updated Studio Name", @collective.name
    assert_equal "Updated description", @collective.description
    assert_response :redirect
  end

  test "non-admin cannot update collective settings" do
    other_user = create_user(name: "Regular User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    original_name = @collective.name

    sign_in_as(other_user, tenant: @tenant)
    post "/studios/#{@collective.handle}/settings",
      params: { name: "Hacked Name" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/settings" }

    @collective.reload
    assert_equal original_name, @collective.name
    assert_response :forbidden
  end

  # === Members Tests ===

  test "authenticated user can view collective members" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/members"
    assert_response :success
  end

  # === Invite Tests ===

  test "admin can access invite page" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/invite"
    assert_response :success
  end

  test "invite page has copy button separate from link box" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/invite"
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
    get "/studios/available", params: { handle: @collective.handle }
    assert_response :success

    json = JSON.parse(response.body)
    assert_not json["available"]
  end

  # === Join Studio Tests ===

  test "user can view join page with valid invite code" do
    # Create a new collective for this test to avoid member conflicts
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    test_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Join Test Studio",
      handle: "join-test-#{SecureRandom.hex(4)}"
    )
    test_collective.add_user!(@user)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    invite = test_collective.find_or_create_shareable_invite(@user)

    # Create a new user who is NOT a member of test_collective
    new_user = create_user(name: "New Member")
    @tenant.add_user!(new_user)
    # Don't add to test_collective

    sign_in_as(new_user, tenant: @tenant)
    get "/studios/#{test_collective.handle}/join", params: { code: invite.code }
    assert_response :success
  end

  # === Scene Tests ===

  test "scene type collective uses scenes route" do
    # Create the scene before signing in
    scene_handle = "test-scene-#{SecureRandom.hex(4)}"
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    scene = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Test Scene",
      handle: scene_handle,
      collective_type: "scene"
    )
    scene.add_user!(@user)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/scenes/#{scene_handle}"
    assert_response :success
  end
end
